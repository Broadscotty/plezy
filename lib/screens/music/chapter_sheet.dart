import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../widgets/focusable_list_tile.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_source_info.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_playback_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/bottom_sheet_header.dart';
import '../../widgets/overlay_sheet.dart';

/// Open the chapter sheet for the music player (audiobooks).
/// The caller's screen must have an [OverlaySheetHost] ancestor (all
/// now-playing layouts do).
Future<void> showChapterSheet(BuildContext context) {
  return OverlaySheetController.of(context).show<void>(showDragHandle: true, builder: (_) => const ChapterSheet());
}

/// Audiobook chapter list for the music player. Fetches chapters through the
/// owning server client (cache-first, so downloaded audiobooks still show
/// chapters while offline), highlights the current chapter against the live
/// playback position, and taps seek to the chapter start.
class ChapterSheet extends StatefulWidget {
  const ChapterSheet({super.key});

  @override
  State<ChapterSheet> createState() => _ChapterSheetState();
}

class _ChapterSheetState extends State<ChapterSheet> {
  Future<PlaybackExtras?>? _extrasFuture;

  @override
  void initState() {
    super.initState();
    // Deferred: context.read is unsafe in initState (the element isn't
    // mounted yet). didChangeDependencies fires once before the first build
    // with a usable context.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _extrasFuture = _loadExtras();
    });
  }

  Future<PlaybackExtras?> _loadExtras() {
    final service = context.read<MusicPlaybackService>();
    final track = service.currentTrack;
    final trackServerId = track?.serverId;
    if (trackServerId == null) return Future.value(null);
    final provider = context.read<MultiServerProvider?>();
    final client = provider?.getClientForServer(ServerId(trackServerId));
    if (client == null) return Future.value(null);
    // Cache-first: works offline for downloaded items, and the cache may be
    // the only source when the owning server is unreachable.
    return client.fetchPlaybackExtras(track!.id).then((extras) {
      if (extras == null || extras.chapters.isNotEmpty) return extras;
      // Whole-track fallback: Plex doesn't surface embedded chapter atoms for
      // audiobooks (Chronicle behaves the same), so when the server returns
      // none we synthesize one chapter per track, mirroring Chronicle's
      // `tracks.asChapterList`. This keeps chapter seek/skip usable for
      // multi-part audiobooks instead of showing an empty sheet.
      final fallback = <MediaChapter>[];
      var cumulativeMs = 0;
      for (final queueItem in service.queue) {
        final durationMs = queueItem.durationMs ?? 0;
        fallback.add(
          MediaChapter(
            id: queueItem.id.hashCode,
            index: fallback.length + 1,
            startTimeOffset: cumulativeMs,
            endTimeOffset: cumulativeMs + durationMs,
            title: queueItem.title,
          ),
        );
        cumulativeMs += durationMs;
      }
      return PlaybackExtras(chapters: fallback, markers: extras.markers);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final service = context.watch<MusicPlaybackService>();
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: .min,
      children: [
        BottomSheetHeader(title: t.videoControls.chapters),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 460),
          child: FutureBuilder<PlaybackExtras?>(
            future: _extrasFuture,
            builder: (context, snapshot) {
              final chapters = snapshot.data?.chapters ?? const <MediaChapter>[];
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (chapters.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    t.videoControls.noChaptersAvailable,
                    style: TextStyle(color: tk.textMuted),
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return StreamBuilder<Duration>(
                stream: service.positionStream,
                initialData: service.position,
                builder: (context, positionSnapshot) {
                  final position = positionSnapshot.data ?? Duration.zero;
                  final currentIndex = MediaChapter.indexAtPosition(position, chapters);
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = chapters[index];
                      final isCurrent = index == currentIndex;
                      return FocusableListTile(
                        title: Text(
                          chapter.label,
                          style: TextStyle(color: isCurrent ? colorScheme.primary : null),
                        ),
                        subtitle: Text(formatDurationTextual(chapter.startTime.inMilliseconds)),
                        leading: isCurrent ? AppIcon(Symbols.play_arrow_rounded, fill: 1, color: colorScheme.primary) : null,
                        onTap: () => unawaited(_seekTo(context, chapter)),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _seekTo(BuildContext context, MediaChapter chapter) async {
    final service = context.read<MusicPlaybackService>();
    await service.seek(chapter.startTime);
    if (context.mounted) OverlaySheetController.of(context).close();
  }
}
