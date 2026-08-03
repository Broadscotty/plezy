import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/book_chapters.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_source_info.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/app_logger.dart';
import 'music_playback_service.dart';

/// Loads and shares the whole-book chapter list for the active music queue.
///
/// [MusicPlaybackService] only knows about the current track; chapters are
/// a book-wide concept spanning every track in the queue, so this fetches
/// each track's chapters once per [MusicPlaybackService.queueSessionRevision]
/// and merges them via [BookChapterBuilder]. The chapter sheet, now-playing
/// screen, and mini player all watch this instead of independently
/// re-fetching the same data.
class BookChapterProvider extends ChangeNotifier {
  final MusicPlaybackService _service;
  final MultiServerProvider? _multiServer;

  int _loadedRevision = -1;
  bool _loading = false;
  List<BookChapter> _chapters = const [];

  BookChapterProvider({required MusicPlaybackService service, required MultiServerProvider? multiServer})
    : _service = service,
      _multiServer = multiServer {
    _service.addListener(_onServiceChanged);
    unawaited(_reload());
  }

  List<BookChapter> get chapters => _chapters;
  bool get loading => _loading;

  /// True only when at least one track returned real embedded chapter data.
  /// A book with none (every track fell back to a single synthesized,
  /// whole-track chapter) still populates [chapters] for skip-track-style
  /// navigation, but callers that only want to show a chapter-title
  /// affordance when there's genuine chapter granularity should check this
  /// instead of `chapters.isNotEmpty`.
  bool get hasChapters => _hasRealChapterData;
  bool _hasRealChapterData = false;

  /// Index into [chapters] for the book position implied by the service's
  /// current track + position. Null while loading or if the queue is empty.
  int? get currentChapterIndex {
    if (_chapters.isEmpty || _service.currentIndex < 0) return null;
    final bookPosition = BookChapterBuilder.bookPositionForQueue(
      queue: _service.queue,
      currentIndex: _service.currentIndex,
      currentTrackPosition: _service.position,
    );
    return BookChapterBuilder.indexAtBookPosition(bookPosition, _chapters);
  }

  BookChapter? get currentChapter {
    final index = currentChapterIndex;
    return index != null ? _chapters[index] : null;
  }

  Future<void> jumpToChapter(BookChapter target) async {
    if (target.queueIndex != _service.currentIndex) {
      await _service.jumpTo(target.queueIndex);
    }
    await _service.seek(target.chapter.startTime);
  }

  Future<void> skipToNextChapter() async {
    final index = currentChapterIndex;
    if (index == null || index >= _chapters.length - 1) return;
    await jumpToChapter(_chapters[index + 1]);
  }

  Future<void> skipToPreviousChapter() async {
    final index = currentChapterIndex;
    if (index == null || index <= 0) return;
    await jumpToChapter(_chapters[index - 1]);
  }

  bool get hasNextChapter {
    final index = currentChapterIndex;
    return index != null && index < _chapters.length - 1;
  }

  bool get hasPreviousChapter {
    final index = currentChapterIndex;
    return index != null && index > 0;
  }

  void _onServiceChanged() {
    if (_service.queueSessionRevision != _loadedRevision) {
      unawaited(_reload());
    } else {
      // Track/position changes don't change the chapter list, but they do
      // change currentChapterIndex — re-notify so consumers re-render.
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    final revision = _service.queueSessionRevision;
    final queue = _service.queue;
    _loadedRevision = revision;
    if (queue.isEmpty) {
      _chapters = const [];
      _hasRealChapterData = false;
      _loading = false;
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();

    final results = await Future.wait(queue.map(_fetchChaptersForTrack));
    // A newer queue session may have started while the fetches above were
    // in flight; discard this stale result rather than overwriting it.
    if (_service.queueSessionRevision != revision) return;

    final chaptersByTrackIndex = <int, List<MediaChapter>?>{};
    for (var i = 0; i < results.length; i++) {
      chaptersByTrackIndex[i] = results[i];
    }
    _chapters = BookChapterBuilder.build(queue: queue, chaptersByTrackIndex: chaptersByTrackIndex);
    _hasRealChapterData = results.any((r) => r != null && r.isNotEmpty);
    _loading = false;
    notifyListeners();
  }

  Future<List<MediaChapter>?> _fetchChaptersForTrack(MediaItem track) async {
    final serverId = serverIdOrNull(track.serverId);
    if (serverId == null) return null;
    final client = _multiServer?.getClientForServer(serverId);
    if (client == null) return null;
    try {
      // Force a fresh fetch: the cache-first path serves any row written
      // for this ratingKey forever, and an early row cached before the file
      // carried chapter tags would otherwise hide real chapters permanently.
      final extras = await client.fetchPlaybackExtras(track.id, forceRefresh: true);
      return extras.chapters;
    } catch (e) {
      appLogger.d('BookChapterProvider: failed to fetch chapters for ${track.id}', error: e);
      return null;
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }
}
