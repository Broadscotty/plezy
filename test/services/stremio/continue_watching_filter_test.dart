import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/stremio/stremio_debrid_client.dart';

/// Continue Watching is meant to be byte-for-byte the clients' list, so these
/// tests pin Stremio's own rule (`LibraryItem::is_in_continue_watching`):
/// type is not "other", the row is not removed unless temporary, and it carries
/// a playback position. No duration, no lastWatched, no credits cut.

Map<String, dynamic> _datastoreItem({
  String type = 'movie',
  String id = 'tt0111161',
  int? duration,
  int? offset,
  String? lastWatched = '2026-10-20T10:00:00.000Z',
  bool removed = false,
  bool temporary = false,
}) => {
  '_id': id,
  'type': type,
  'name': 'Test item',
  'removed': removed,
  'temp': temporary,
  'state': {
    if (duration != null) 'duration': duration,
    if (offset != null) 'timeOffset': offset,
    if (lastWatched != null) 'lastWatched': lastWatched,
  },
};

void main() {
  group('StremioDebridClient.isInContinueWatching', () {
    test('a row with a position is in, exactly as the clients do it', () {
      expect(StremioDebridClient.isInContinueWatching(_datastoreItem(duration: 6000000, offset: 2400000)), isTrue);
    });

    test('a row at the credits still counts -- the clients do not cut there', () {
      expect(StremioDebridClient.isInContinueWatching(_datastoreItem(duration: 6000000, offset: 5990000)), isTrue);
    });

    test('a position with no duration counts', () {
      expect(StremioDebridClient.isInContinueWatching(_datastoreItem(duration: 0, offset: 45000)), isTrue);
    });

    test('no lastWatched is fine -- position alone decides', () {
      expect(StremioDebridClient.isInContinueWatching(_datastoreItem(offset: 45000, lastWatched: null)), isTrue);
    });

    test('zero position is out', () {
      expect(StremioDebridClient.isInContinueWatching(_datastoreItem(duration: 6000000, offset: 0)), isFalse);
    });

    test('only type "other" is excluded by type', () {
      expect(StremioDebridClient.isInContinueWatching(_datastoreItem(type: 'other', offset: 45000)), isFalse);
      expect(StremioDebridClient.isInContinueWatching(_datastoreItem(type: 'channel', offset: 45000)), isTrue);
    });

    test('a removed row is out unless it is temporary', () {
      expect(StremioDebridClient.isInContinueWatching(_datastoreItem(offset: 45000, removed: true)), isFalse);
      expect(
        StremioDebridClient.isInContinueWatching(_datastoreItem(offset: 45000, removed: true, temporary: true)),
        isTrue,
      );
    });
  });

  group('StremioDebridClient.sortContinueWatching', () {
    Map<String, dynamic> dated(String id, String lastWatched) =>
        _datastoreItem(id: id, duration: 6000000, offset: 1200000, lastWatched: lastWatched);

    test('most recently watched first', () {
      final sorted = StremioDebridClient.sortContinueWatching([
        dated('tt0000001', '2026-10-01T10:00:00.000Z'),
        dated('tt0000002', '2026-10-24T10:00:00.000Z'),
        dated('tt0000003', '2026-10-12T10:00:00.000Z'),
      ]);

      expect(sorted.map((i) => i['_id']).toList(), ['tt0000002', 'tt0000003', 'tt0000001']);
    });

    test('keeps every row -- no cap', () {
      final items = [
        for (var day = 1; day <= 30; day++)
          dated('tt00000${day.toString().padLeft(2, '0')}', '2026-09-${day.toString().padLeft(2, '0')}T10:00:00.000Z'),
      ];

      expect(StremioDebridClient.sortContinueWatching(items), hasLength(30));
    });
  });
}
