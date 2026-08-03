import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../widgets/focusable_list_tile.dart';
import '../../i18n/strings.g.dart';
import '../../media/playback_rate.dart';
import '../../services/music/music_playback_service.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/bottom_sheet_header.dart';
import '../../widgets/overlay_sheet.dart';

/// Open the playback-speed sheet for the music player (audiobooks).
/// The caller's screen must have an [OverlaySheetHost] ancestor (all
/// now-playing layouts do).
Future<void> showSpeedSheet(BuildContext context) {
  return OverlaySheetController.of(context).show<void>(showDragHandle: true, builder: (_) => const SpeedSheet());
}

/// Speed picker for the music player. Mirrors the video player's preset list
/// (0.25x–8x) and persists the selection as the default playback speed so an
/// audiobook user's pace survives track changes and restarts.
class SpeedSheet extends StatelessWidget {
  const SpeedSheet({super.key});

  static const List<double> presets = [
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
    2.25,
    2.5,
    2.75,
    3.0,
    3.5,
    4.0,
    5.0,
    6.0,
    8.0,
  ];

  @override
  Widget build(BuildContext context) {
    final service = context.watch<MusicPlaybackService>();
    final colorScheme = Theme.of(context).colorScheme;
    final currentRate = service.playbackSpeed;

    return Column(
      mainAxisSize: .min,
      children: [
        BottomSheetHeader(
          title: t.videoSettings.playbackSpeed,
          action: Text(
            formatPlaybackRate(currentRate, normalAtOne: true),
            style: TextStyle(fontSize: 13, color: colorScheme.primary),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: presets.length,
            itemBuilder: (context, index) {
              final speed = presets[index];
              final isSelected = (currentRate - speed).abs() < 0.01;
              final label = formatPlaybackRate(speed, normalAtOne: true);
              return FocusableListTile(
                title: Text(label, style: TextStyle(color: isSelected ? colorScheme.primary : null)),
                trailing: isSelected ? AppIcon(Symbols.check_rounded, fill: 1, color: colorScheme.primary) : null,
                onTap: () async {
                  await service.setPlaybackSpeed(speed);
                  if (context.mounted) OverlaySheetController.of(context).close();
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
