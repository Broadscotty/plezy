import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/stremio/stremio_api_client.dart';
import 'package:plezy/services/stremio/stremio_debrid_client.dart';

/// Continue Watching must list what Stremio's own clients list: a real
/// in-progress position, and never a show parked on an episode the account
/// already counts as watched.

Map<String, dynamic> _datastoreItem({
  String type = 'movie',
  String id = 'tt0111161',
  int? duration,
  int? offset,
  String? lastWatched = '2026-10-20T10:00:00.000Z',
  String? videoId,
  String? watched,
}) => {
  '_id': id,
  'type': type,
  'name': 'Test item',
  'state': {
    if (duration != null) 'duration': duration,
    if (offset != null) 'timeOffset': offset,
    if (lastWatched != null) 'lastWatched': lastWatched,
    if (videoId != null) 'video_id': videoId,
    if (watched != null) 'watched': watched,
  },
};

void main() {
  group('StremioDebridClient.hasUnfinishedPosition', () {
    test('a movie part-way through is continue-watching material', () {
      final item = _datastoreItem(duration: 6000000, offset: 2400000);

      expect(StremioDebridClient.hasUnfinishedPosition(item), isTrue);
    });

    test('a movie at the credits is not', () {
      final item = _datastoreItem(duration: 6000000, offset: 5900000);

      expect(StremioDebridClient.hasUnfinishedPosition(item), isFalse);
    });

    test('a row with no lastWatched was never played, so it is excluded', () {
      final item = _datastoreItem(duration: 6000000, offset: 2400000, lastWatched: null);

      expect(StremioDebridClient.hasUnfinishedPosition(item), isFalse);
    });

    test('zero duration or zero offset is excluded', () {
      expect(StremioDebridClient.hasUnfinishedPosition(_datastoreItem(duration: 0, offset: 1000)), isFalse);
      expect(StremioDebridClient.hasUnfinishedPosition(_datastoreItem(duration: 6000000, offset: 0)), isFalse);
    });

    test('non watchable datastore types (channels, tv) are excluded', () {
      final item = _datastoreItem(type: 'channel', duration: 6000000, offset: 2400000);

      expect(StremioDebridClient.hasUnfinishedPosition(item), isFalse);
    });
  });

  group('StremioDebridClient.isParkedOnWatchedEpisode', () {
    const videoIds = ['tt0944947:1:1', 'tt0944947:1:2', 'tt0944947:1:3'];

    test('parked episode already marked watched is not continue-watching', () {
      final item = _datastoreItem(
        type: 'series',
        id: 'tt0944947',
        duration: 3600000,
        offset: 1800000,
        videoId: 'tt0944947:1:2',
        watched: encodeWatchedBitfield({'tt0944947:1:2'}, videoIds),
      );

      expect(StremioDebridClient.isParkedOnWatchedEpisode(item, videoIds), isTrue);
    });

    test('parked episode still unwatched keeps the show in continue watching', () {
      final item = _datastoreItem(
        type: 'series',
        id: 'tt0944947',
        duration: 3600000,
        offset: 1800000,
        videoId: 'tt0944947:1:2',
        watched: encodeWatchedBitfield({'tt0944947:1:1'}, videoIds),
      );

      expect(StremioDebridClient.isParkedOnWatchedEpisode(item, videoIds), isFalse);
    });

    test('no episode list available means no exclusion', () {
      final item = _datastoreItem(
        type: 'series',
        id: 'tt0944947',
        videoId: 'tt0944947:1:2',
        watched: encodeWatchedBitfield({'tt0944947:1:2'}, videoIds),
      );

      expect(StremioDebridClient.isParkedOnWatchedEpisode(item, const []), isFalse);
    });
  });
}
