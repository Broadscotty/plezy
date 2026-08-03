import 'media_item.dart';
import 'media_source_info.dart';

/// A chapter merged into a whole-book, multi-track timeline.
///
/// Plex/Jellyfin chapters are reported per audio file ([MediaChapter]'s
/// offsets are relative to the *track* that contains them). For a
/// multi-file audiobook, the sheet needs one flat, seekable list spanning
/// every track — this wraps each chapter with the [queueIndex] of the track
/// it belongs to and its [bookStartOffset]: the chapter's start position
/// relative to the start of the whole book, used to find/highlight the
/// current chapter across track boundaries the same way a single-file book
/// finds it across chapter boundaries.
class BookChapter {
  final MediaChapter chapter;
  final int queueIndex;
  final Duration bookStartOffset;

  const BookChapter({required this.chapter, required this.queueIndex, required this.bookStartOffset});

  String get label => chapter.label;
}

/// Builds a book-wide, multi-track chapter list and applies the fallback /
/// filtering behaviour Chronicle uses for the same Plex data (see
/// fabiogermann/chronicle, docs/features/chapters.md):
///
///  - **Transition markers**: Plex sometimes reports a genuine chapter plus
///    a sub-second (~40-50ms) boundary marker at the same split point. Left
///    unfiltered, the marker shows up as a duplicate `0:00` row. Filtered
///    only when the same track already has a chapter that isn't itself a
///    sub-second entry — a book that genuinely has only short chapters keeps
///    them.
///  - **Per-track fallback**: a track that returns no embedded chapters at
///    all gets a single synthesized chapter spanning its full duration
///    (title = track title). This only replaces the fallback for *that*
///    track — sibling tracks that do have real chapters keep them, unlike
///    an all-or-nothing whole-book fallback.
class BookChapterBuilder {
  static const _transitionMarkerMs = 1000;

  /// [chaptersByTrackIndex] holds one fetch result per queue index that was
  /// attempted. A missing key or a `null` value means "not fetched / fetch
  /// failed" and is treated the same as an empty list (triggers the
  /// per-track fallback) — a network hiccup on one track's chapters
  /// shouldn't hide the rest of the book.
  static List<BookChapter> build({
    required List<MediaItem> queue,
    required Map<int, List<MediaChapter>?> chaptersByTrackIndex,
  }) {
    final result = <BookChapter>[];
    var cumulativeMs = 0;
    for (var i = 0; i < queue.length; i++) {
      final track = queue[i];
      final durationMs = track.durationMs ?? 0;
      final fetched = chaptersByTrackIndex[i];
      final trackChapters = (fetched == null || fetched.isEmpty)
          ? <MediaChapter>[
              MediaChapter(id: track.id.hashCode, index: 0, startTimeOffset: 0, endTimeOffset: durationMs, title: track.title),
            ]
          : _filterTransitionMarkers(fetched);
      for (final chapter in trackChapters) {
        result.add(
          BookChapter(
            chapter: chapter,
            queueIndex: i,
            bookStartOffset: Duration(milliseconds: cumulativeMs + (chapter.startTimeOffset ?? 0)),
          ),
        );
      }
      cumulativeMs += durationMs;
    }
    return result;
  }

  static List<MediaChapter> _filterTransitionMarkers(List<MediaChapter> chapters) {
    final hasRealChapter = chapters.any((c) => _durationMs(c, chapters) >= _transitionMarkerMs);
    if (!hasRealChapter) return chapters;
    return chapters.where((c) => _durationMs(c, chapters) >= _transitionMarkerMs).toList();
  }

  static int _durationMs(MediaChapter chapter, List<MediaChapter> all) {
    final start = chapter.startTimeOffset ?? 0;
    if (chapter.endTimeOffset != null) return chapter.endTimeOffset! - start;
    final i = all.indexOf(chapter);
    final nextStart = (i >= 0 && i < all.length - 1) ? all[i + 1].startTimeOffset : null;
    return (nextStart ?? start) - start;
  }

  /// Current position expressed as an offset from the start of the whole
  /// book, given the queue and the position within the currently playing
  /// track.
  static Duration bookPositionForQueue({
    required List<MediaItem> queue,
    required int currentIndex,
    required Duration currentTrackPosition,
  }) {
    var cumulativeMs = 0;
    for (var i = 0; i < currentIndex && i < queue.length; i++) {
      cumulativeMs += queue[i].durationMs ?? 0;
    }
    return Duration(milliseconds: cumulativeMs) + currentTrackPosition;
  }

  /// Index into [chapters] (already sorted by [BookChapter.bookStartOffset]
  /// since [build] emits them in queue order) containing [bookPosition].
  /// Returns null only when [chapters] is empty.
  static int? indexAtBookPosition(Duration bookPosition, List<BookChapter> chapters) {
    if (chapters.isEmpty) return null;
    final ms = bookPosition.inMilliseconds;
    for (var i = 0; i < chapters.length; i++) {
      final startMs = chapters[i].bookStartOffset.inMilliseconds;
      final endMs = i < chapters.length - 1 ? chapters[i + 1].bookStartOffset.inMilliseconds : double.maxFinite.toInt();
      if (ms >= startMs && ms < endMs) return i;
    }
    return chapters.length - 1;
  }
}
