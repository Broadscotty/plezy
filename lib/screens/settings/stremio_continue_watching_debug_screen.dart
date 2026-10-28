import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../services/credential_vault.dart';
import '../../services/settings_service.dart';
import '../../services/stremio/stremio_api_client.dart';
import '../../services/stremio/stremio_debrid_client.dart';
import '../../widgets/focused_scroll_scaffold.dart';

/// Why the Continue Watching row looks the way it does.
///
/// There is no adb on the target phone, so the account datastore has to be
/// readable on the device itself: every row the account holds, its progress,
/// how old its lastWatched stamp is, and whether Plezy keeps or drops it.
/// Copy button puts the whole table on the clipboard for pasting into chat.
class StremioContinueWatchingDebugScreen extends StatefulWidget {
  const StremioContinueWatchingDebugScreen({super.key});

  @override
  State<StremioContinueWatchingDebugScreen> createState() => _StremioContinueWatchingDebugScreenState();
}

class _StremioContinueWatchingDebugScreenState extends State<StremioContinueWatchingDebugScreen> {
  bool _loading = true;
  String? _error;
  String _report = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await SettingsService.getInstance();
      final stored = settings.read(SettingsService.stremioAuthKey);
      if (stored == null) throw StateError('Stremio account is not connected');
      final String protectedKey = stored;
      final authKey = await CredentialVault.reveal(protectedKey);
      final items = await StremioApiClient().getAllItems(authKey);
      final report = buildContinueWatchingReport(items, DateTime.now());
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: const Text('Continue Watching rows'),
      slivers: [
        if (_loading)
          const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
              ),
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'IN = shown in Continue Watching, OUT = filtered, with the reason.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Symbols.content_copy_rounded),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _report));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                    },
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: SelectableText(
                _report,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.5),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Builds the plain-text table. Pure so it can be unit-tested.
String buildContinueWatchingReport(List<Map<String, dynamic>> items, DateTime now) {
  final rows = items.where((i) => i['removed'] != true).toList();
  final lines = <String>[];
  final kept = rows.where(StremioDebridClient.hasUnfinishedPosition).length;
  lines.add('rows=${rows.length} inContinueWatching=$kept');
  lines.add('IN/OUT  title | type | progress | lastWatched | timesWatched | watchedField');

  final parsed = rows.map((item) {
    final state = item['state'] is Map<String, dynamic> ? item['state'] as Map<String, dynamic> : const <String, dynamic>{};
    final stamp = '${state['lastWatched'] ?? ''}';
    return (item: item, state: state, at: DateTime.tryParse(stamp));
  }).toList()
    ..sort((a, b) {
      final ax = a.at?.millisecondsSinceEpoch ?? 0;
      final bx = b.at?.millisecondsSinceEpoch ?? 0;
      return bx.compareTo(ax);
    });

  for (final row in parsed.take(60)) {
    final state = row.state;
    final duration = int.tryParse('${state['duration'] ?? 0}') ?? 0;
    final offset = int.tryParse('${state['timeOffset'] ?? 0}') ?? 0;
    final pct = duration > 0 ? (100 * offset / duration).round() : 0;
    final age = row.at == null ? 'none' : '${now.difference(row.at!.toLocal()).inDays}d';
    final timesWatched = state['timesWatched'] ?? 0;
    final watchedField = (state['watched'] is String && (state['watched'] as String).isNotEmpty) ? 'yes' : 'no';
    final verdict = StremioDebridClient.hasUnfinishedPosition(row.item) ? 'IN ' : 'OUT';
    final reason = verdict == 'IN ' ? '' : '  <- ${_reason(row.item, duration, offset, row.at)}';
    lines.add(
      '$verdict  ${row.item['name'] ?? row.item['_id']} | ${row.item['type']} | $pct% | $age | $timesWatched | $watchedField$reason',
    );
  }
  return lines.join('\n');
}

String _reason(Map<String, dynamic> item, int duration, int offset, DateTime? lastWatched) {
  final type = '${item['type']}';
  if (type != 'movie' && type != 'series') return 'type $type';
  if (duration <= 0) return 'no duration';
  if (offset <= 0) return 'no progress';
  if (offset >= duration * 0.97) return 'at credits';
  if (lastWatched == null) return 'no lastWatched';
  return 'unknown';
}
