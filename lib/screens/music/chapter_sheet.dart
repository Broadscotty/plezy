import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../widgets/focusable_list_tile.dart';
import '../../i18n/strings.g.dart';
import '../../media/book_chapters.dart';
import '../../services/music/book_chapter_provider.dart';
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

/// Whole-book chapter list for the music player. Reads [BookChapterProvider]
/// — chapters for every track in the queue, merged into one book-relative
/// list — highlights the chapter at the live playback position, and taps
/// jump/seek to the chapter start (crossing track boundaries when needed).
class ChapterSheet extends StatelessWidget {
  const ChapterSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final bookChapters = context.watch<BookChapterProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: .min,
      children: [
        BottomSheetHeader(title: t.videoControls.chapters),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 460),
          child: _buildBody(context, tk, colorScheme, bookChapters),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, MonoTokens tk, ColorScheme colorScheme, BookChapterProvider bookChapters) {
    if (bookChapters.loading) {
      return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    }
    final chapters = bookChapters.chapters;
    if (chapters.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(t.videoControls.noChaptersAvailable, style: TextStyle(color: tk.textMuted), textAlign: TextAlign.center),
      );
    }
    final currentIndex = bookChapters.currentChapterIndex;
    return ListView.builder(
      shrinkWrap: true,
      itemCount: chapters.length,
      itemBuilder: (context, index) {
        final bookChapter = chapters[index];
        final isCurrent = index == currentIndex;
        return FocusableListTile(
          title: Text(bookChapter.label, style: TextStyle(color: isCurrent ? colorScheme.primary : null)),
          subtitle: Text(formatDurationTextual(bookChapter.bookStartOffset.inMilliseconds)),
          leading: isCurrent ? AppIcon(Symbols.play_arrow_rounded, fill: 1, color: colorScheme.primary) : null,
          onTap: () => unawaited(_jumpTo(context, bookChapter)),
        );
      },
    );
  }

  Future<void> _jumpTo(BuildContext context, BookChapter chapter) async {
    final bookChapters = context.read<BookChapterProvider>();
    await bookChapters.jumpToChapter(chapter);
    if (context.mounted) OverlaySheetController.of(context).close();
  }
}
