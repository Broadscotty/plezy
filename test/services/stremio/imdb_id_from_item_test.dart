import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/stremio/stremio_sync_service.dart';

import '../../test_helpers/media_items.dart';

/// Stremio sync must resolve an IMDb id even when no media server client is on
/// the playback path (downloaded / offline playback), otherwise the hook is
/// skipped and the settings panel shows "no playback attempted".
void main() {
  group('StremioSyncService.imdbIdFromItem', () {
    test('movie takes the IMDb id from its Stremio raw id', () {
      final item = testMediaItem(
        id: 'movie|tt0111161',
        kind: MediaKind.movie,
        raw: {'stremioId': 'tt0111161'},
      );

      expect(StremioSyncService.imdbIdFromItem(item), 'tt0111161');
    });

    test('movie falls back to the item id when raw is absent', () {
      final item = testMediaItem(id: 'movie|tt0068646', kind: MediaKind.movie);

      expect(StremioSyncService.imdbIdFromItem(item), 'tt0068646');
    });

    test('episode takes the show id from grandparentId', () {
      final item = testMediaItem(
        id: 'series|tt0944947:1:2',
        kind: MediaKind.episode,
        grandparentId: 'series|tt0944947',
        parentIndex: 1,
        index: 2,
        raw: {'stremioId': 'tt0944947:1:2'},
      );

      expect(StremioSyncService.imdbIdFromItem(item), 'tt0944947');
    });

    test('episode strips the season/episode suffix from a video-style id', () {
      final item = testMediaItem(
        id: 'series|tt0944947:1:2',
        kind: MediaKind.episode,
        grandparentId: 'series|tt0944947:1:2',
        parentIndex: 1,
        index: 2,
      );

      expect(StremioSyncService.imdbIdFromItem(item), 'tt0944947');
    });

    test('non-IMDb addon ids resolve to null so the panel can name the skip', () {
      final item = testMediaItem(
        id: 'series|hpy123',
        kind: MediaKind.episode,
        grandparentId: 'series|hpy123',
        parentIndex: 1,
        index: 2,
      );

      expect(StremioSyncService.imdbIdFromItem(item), isNull);
    });
  });
}
