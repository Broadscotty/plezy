import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../media/ids.dart';
import '../media/media_server_client.dart';
import '../providers/multi_server_provider.dart';
import '../services/credential_vault.dart';
import '../services/settings_service.dart';
import '../services/stremio/stremio_api_client.dart';
import '../services/stremio/stremio_debrid_client.dart';
import '../utils/app_logger.dart';
import '../utils/media_navigation_helper.dart';
import '../widgets/app_icon.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/loading_indicator_box.dart';
import '../widgets/optimized_media_image.dart';

/// Read-only browser for the connected account's Stremio library — the
/// `libraryItem` datastore pulled with `datastoreGet {all: true}`, the same
/// collection the official clients render as "My Library".
///
/// Each tile shows what Stremio knows: poster, watched state (movies via
/// `timesWatched`, series via the watched bitfield decoded against Cinemeta's
/// episode order — same decode the sync service writes), and in-progress
/// progress from `timeOffset`/`duration`. Tapping an item opens the normal
/// detail screen through the debrid backend, so library browsing ends in
/// playback the same way every other screen does.
/// Which Stremio surface the screen renders: the account's full library, or
/// only items with an unfinished playback position (Continue Watching).
enum StremioViewMode { library, continueWatching }

class StremioLibraryScreen extends StatefulWidget {
  /// Whether to show the full library or just in-progress items.
  final StremioViewMode mode;

  const StremioLibraryScreen({super.key, this.mode = StremioViewMode.library});

  @override
  State<StremioLibraryScreen> createState() => _StremioLibraryScreenState();
}

class _StremioLibraryScreenState extends State<StremioLibraryScreen> {
  final StremioApiClient _api = StremioApiClient();

  /// Episode-order lookups for series watched-counts, keyed by IMDb id.
  /// Process-lifetime cache — revisit cost is one Cinemeta call per show.
  final Map<String, Future<List<String>>> _episodeIds = {};

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await SettingsService.getInstance();
      final protected = settings.read(SettingsService.stremioAuthKey);
      if (protected == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Not connected. Connect your account in Settings → Services → Stremio first.';
        });
        return;
      }
      final authKey = await CredentialVault.reveal(protected);
      if (authKey == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Stored Stremio credentials could not be read. Reconnect the account.';
        });
        return;
      }
      final items = await _api.getAllItems(authKey);
      var visible = items.where((i) => i['removed'] != true).toList();
      if (widget.mode == StremioViewMode.continueWatching) {
        visible = visible.where(_inProgress).toList();
        // Most recently watched first — the order Stremio's own Continue
        // Watching uses.
        visible.sort((a, b) => _lastWatched(b).compareTo(_lastWatched(a)));
      } else {
        visible.sort((a, b) {
          final am = '${a['_mtime'] ?? ''}';
          final bm = '${b['_mtime'] ?? ''}';
          return bm.compareTo(am);
        });
      }
      if (!mounted) return;
      setState(() {
        _items = visible;
        _loading = false;
      });
    } catch (e) {
      appLogger.w('Stremio library load failed', error: e);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your Stremio library: $e';
      });
    }
  }

  Map<String, dynamic> _stateOf(Map<String, dynamic> item) {
    final state = item['state'];
    return state is Map<String, dynamic> ? state : const <String, dynamic>{};
  }

  int _asInt(Object? value) => int.tryParse('${value ?? 0}') ?? 0;

  /// True when the item has a real, unfinished playback position. Untouched
  /// items default to a zeroed state and finished ones sit at (nearly) the
  /// full duration, so both drop out.
  bool _inProgress(Map<String, dynamic> item) {
    final state = _stateOf(item);
    final duration = _asInt(state['duration']);
    final offset = _asInt(state['timeOffset']);
    return duration > 0 && offset > 0 && offset < duration * 0.97;
  }

  /// ISO-8601 `lastWatched` timestamp for recency sorting; empty when absent.
  String _lastWatched(Map<String, dynamic> item) {
    final value = _stateOf(item)['lastWatched'];
    final text = value == null ? '' : '$value';
    return text == 'null' ? '' : text;
  }

  /// Poster-overlay progress bar fraction, Continue Watching mode only.
  double? _progressFraction(Map<String, dynamic> item) {
    if (widget.mode != StremioViewMode.continueWatching) return null;
    final state = _stateOf(item);
    final duration = _asInt(state['duration']);
    final offset = _asInt(state['timeOffset']);
    if (duration <= 0 || offset <= 0) return null;
    return (offset / duration).clamp(0.0, 1.0);
  }

  MediaServerClient? _debridClient() {
    final manager = context.read<MultiServerProvider>().serverManager;
    for (final id in manager.serverIds) {
      final client = manager.getClient(ServerId(id));
      if (client is StremioDebridClient) return client;
    }
    return null;
  }

  Future<void> _open(Map<String, dynamic> item) async {
    final id = item['_id'];
    final type = item['type'];
    if (id is! String || type is! String) return;
    final client = _debridClient();
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add your debrid server to open library items.')),
      );
      return;
    }
    try {
      final media = await client.fetchItem(StremioItemId(type, id).toString());
      if (!mounted) return;
      if (media == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Item not found on your server.')));
        return;
      }
      await navigateToMediaItem(context, media);
    } catch (e) {
      appLogger.w('Stremio library open failed for $id', error: e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open item: $e')));
    }
  }

  /// Watched/progress summary rendered under a tile's poster.
  (String, bool) _status(Map<String, dynamic> item, {bool preferProgress = false}) {
    final state = item['state'];
    final map = state is Map<String, dynamic> ? state : const <String, dynamic>{};
    final type = '${item['type']}';
    final duration = int.tryParse('${map['duration'] ?? 0}') ?? 0;
    final offset = int.tryParse('${map['timeOffset'] ?? 0}') ?? 0;
    final lastWatched = '${map['lastWatched'] ?? ''}';

    bool watched = false;
    if (type == 'movie') {
      watched = (int.tryParse('${map['timesWatched'] ?? 0}') ?? 0) > 0;
    } else if (map['watched'] is String && (map['watched'] as String).isNotEmpty) {
      // Series watched-set size needs the episode list — resolved async in
      // [_StatusLine]; here just flag "has watched episodes".
      watched = true;
    }

    // Continue Watching leads with how far along the item is, even when the
    // show already has watched episodes recorded.
    if (preferProgress && duration > 0 && offset > 0 && offset < duration) {
      final percent = (100 * offset / duration).clamp(0, 100).round();
      return ('$percent%', false);
    }
    if (watched) return ('Watched', true);
    if (duration > 0 && offset > 0) {
      final percent = (100 * offset / duration).clamp(0, 100).round();
      return ('$percent%', false);
    }
    if (lastWatched.isNotEmpty && lastWatched != 'null') {
      final parsed = DateTime.tryParse(lastWatched);
      if (parsed != null) {
        final local = parsed.toLocal();
        final two = (int n) => n.toString().padLeft(2, '0');
        return ('Last played ${two(local.day)}/${two(local.month)}', false);
      }
    }
    return ('', false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(
        widget.mode == StremioViewMode.continueWatching ? 'Stremio Continue Watching' : 'Stremio Library',
      ),
      slivers: [
        if (_loading)
          const SliverFillRemaining(hasScrollBody: false, child: Center(child: LoadingIndicatorBox()))
        else if (_error != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            ),
          )
        else if (_items.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                widget.mode == StremioViewMode.continueWatching
                    ? 'Nothing in progress on Stremio right now.'
                    : 'Your Stremio library is empty.',
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                childAspectRatio: 0.62,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = _items[index];
                final title = '${item['name'] ?? item['_id'] ?? ''}';
                final poster = item['poster'];
                final (status, isWatched) = _status(
                  item,
                  preferProgress: widget.mode == StremioViewMode.continueWatching,
                );
                final fraction = _progressFraction(item);
                return InkWell(
                  onTap: () => unawaited(_open(item)),
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              OptimizedMediaImage.poster(
                                imagePath: poster is String ? poster : null,
                                fallbackIcon: Symbols.movie_rounded,
                              ),
                              if (isWatched)
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.surface.withValues(alpha: 0.85),
                                      shape: BoxShape.circle,
                                    ),
                                    child: AppIcon(
                                      Symbols.check_circle_rounded,
                                      size: 18,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              if (fraction != null)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: LinearProgressIndicator(
                                    value: fraction,
                                    minHeight: 4,
                                    backgroundColor: Colors.black26,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      if (status.isNotEmpty)
                        _StatusLine(item: item, label: status, api: _api, episodeIds: _episodeIds),
                    ],
                  ),
                );
              }, childCount: _items.length),
            ),
          ),
      ],
    );
  }
}

/// Small status row under a library tile. For series with a watched set it
/// swaps the generic "Watched" label for the real episode count, resolving
/// the bitfield against Cinemeta once per show.
class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.item,
    required this.label,
    required this.api,
    required this.episodeIds,
  });

  final Map<String, dynamic> item;
  final String label;
  final StremioApiClient api;
  final Map<String, Future<List<String>>> episodeIds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isGenericWatched = label == 'Watched' && '${item['type']}' == 'series';
    if (!isGenericWatched) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: FutureBuilder<int>(
        future: _count(),
        builder: (context, snapshot) {
          final text = snapshot.hasData ? '${snapshot.data} watched' : 'Watched';
          return Text(text, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor));
        },
      ),
    );
  }

  Future<int> _count() async {
    final id = item['_id'];
    if (id is! String) return 0;
    final state = item['state'];
    final serialized = state is Map<String, dynamic> ? state['watched'] : null;
    if (serialized is! String || serialized.isEmpty) return 0;
    final future = episodeIds[id] ??= api.seriesVideoIds(id);
    final videoIds = await future;
    return decodeWatchedBitfield(serialized, videoIds).length;
  }
}
