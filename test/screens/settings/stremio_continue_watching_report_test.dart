import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/settings/stremio_continue_watching_debug_screen.dart';

Map<String, dynamic> _row({
  required String id,
  required String type,
  int duration = 6000000,
  int offset = 1200000,
  String? lastWatched = '2026-10-20T10:00:00.000Z',
  int timesWatched = 0,
}) => {
  '_id': id,
  'name': id,
  'type': type,
  'removed': false,
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
  test('report counts what is kept and names why the rest is dropped', () {
    final report = buildContinueWatchingReport([
      _row(id: 'Kept Show', type: 'series'),
      _row(id: 'Finished Movie', type: 'movie', offset: 5950000),
      _row(id: 'Never Played', type: 'movie', offset: 0),
      _row(id: 'No Stamp', type: 'movie', lastWatched: null),
      _row(id: 'A Channel', type: 'channel'),
    ], DateTime.utc(2026, 10, 28));

    expect(report, contains('rows=5 inContinueWatching=1'));
    expect(report, contains('IN   Kept Show | series | 20% | 7d'));
    expect(report, contains('at credits'));
    expect(report, contains('no progress'));
    expect(report, contains('no lastWatched'));
    expect(report, contains('type channel'));
  });

  test('newest lastWatched first', () {
    final report = buildContinueWatchingReport([
      _row(id: 'Older', type: 'movie', lastWatched: '2026-09-01T10:00:00.000Z'),
      _row(id: 'Newer', type: 'movie', lastWatched: '2026-10-27T10:00:00.000Z'),
    ], DateTime.utc(2026, 10, 28));

    expect(report.indexOf('Newer'), lessThan(report.indexOf('Older')));
  });
}
