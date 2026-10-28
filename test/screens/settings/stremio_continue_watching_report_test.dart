import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/settings/stremio_continue_watching_debug_screen.dart';

Map<String, dynamic> _row({
  required String id,
  required String type,
  int duration = 6000000,
  int offset = 1200000,
  String? lastWatched = '2026-10-20T10:00:00.000Z',
  int timesWatched = 0,
  bool removed = false,
  bool temporary = false,
}) => {
  '_id': id,
  'name': id,
  'type': type,
  'removed': removed,
  'temp': temporary,
  'state': {
    'duration': duration,
    'timeOffset': offset,
    if (lastWatched != null) 'lastWatched': lastWatched,
    'timesWatched': timesWatched,
  },
};

/// The diagnostics screen is the only window onto the account datastore on the
/// phone, so its report has to name the reason a row is dropped.
void main() {
  test('report follows the clients: position decides, nothing else', () {
    final report = buildContinueWatchingReport([
      _row(id: 'Kept Show', type: 'series'),
      _row(id: 'Finished Movie', type: 'movie', offset: 5950000),
      _row(id: 'Never Played', type: 'movie', offset: 0),
      _row(id: 'No Stamp', type: 'movie', lastWatched: null),
      _row(id: 'A Channel', type: 'channel'),
    ], DateTime.utc(2026, 10, 28));

    expect(report, contains('rows=5 inContinueWatching=4'));
    expect(report, contains('IN   Kept Show | series | 20% | 7d'));
    // At-the-credits, no-stamp and non movie/series rows are all still in:
    // only "other", removal and a zero position drop a row.
    expect(report, contains('IN   Finished Movie'));
    expect(report, contains('IN   No Stamp'));
    expect(report, contains('IN   A Channel'));
    expect(report, contains('no progress'));
  });

  test('the age window is optional and named when it bites', () {
    final withWindow = buildContinueWatchingReport([
      _row(id: 'Ancient', type: 'movie', lastWatched: '2026-06-01T10:00:00.000Z'),
    ], DateTime.utc(2026, 10, 28), maxAge: const Duration(days: 90));

    expect(withWindow, contains('inContinueWatching=0 (window 90d)'));
    expect(withWindow, contains('older than 90d'));

    final without = buildContinueWatchingReport([
      _row(id: 'Ancient', type: 'movie', lastWatched: '2026-06-01T10:00:00.000Z'),
    ], DateTime.utc(2026, 10, 28));

    expect(without, contains('inContinueWatching=1 (window anyd)'));
  });

  test('newest lastWatched first', () {
    final report = buildContinueWatchingReport([
      _row(id: 'Older', type: 'movie', lastWatched: '2026-09-01T10:00:00.000Z'),
      _row(id: 'Newer', type: 'movie', lastWatched: '2026-10-27T10:00:00.000Z'),
    ], DateTime.utc(2026, 10, 28));

    expect(report.indexOf('Newer'), lessThan(report.indexOf('Older')));
  });
}
