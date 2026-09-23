import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Errors raised while talking to Stremio's account APIs.
class StremioApiException implements Exception {
  StremioApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => code != null ? 'StremioApiException($code): $message' : 'StremioApiException: $message';
}

/// A pending device-link code from `link.stremio.com`.
class StremioLinkCode {
  const StremioLinkCode({required this.code, required this.link});

  final String code;

  /// The approval URL to open in a browser.
  final String link;
}

/// Unofficial Stremio account API client (auth + cloud datastore).
///
/// Payload shapes are mirrored byte-for-byte from two independent working
/// implementations — MDBridge (GPLv3) and Scrob (GPLv3) — which both read and
/// write the same `libraryItem` datastore the official Stremio clients use.
/// Stremio can change this API without notice; every call here fails soft and
/// the caller is expected to swallow errors rather than disturb playback.
class StremioApiClient {
  StremioApiClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static const String _apiBase = 'https://api.strem.io/api';
  static const String _linkBase = 'https://link.stremio.com/api/v2';
  static const String _cinemetaBase = 'https://v3-cinemeta.strem.io';
  static const String libraryCollection = 'libraryItem';

  final http.Client _http;

  final Map<String, List<String>> _videoIdCache = {};

  Future<dynamic> _post(String path, Map<String, dynamic> body) async {
    final response = await _http
        .post(
          Uri.parse('$_apiBase/$path'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StremioApiException('HTTP ${response.statusCode} on $path');
    }
    final Object? payload;
    try {
      payload = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw StremioApiException('malformed JSON on $path: ${e.message}');
    }
    if (payload is! Map<String, dynamic>) throw StremioApiException('unexpected response shape on $path');
    final error = payload['error'];
    if (error != null) {
      final code = error is Map ? int.tryParse('${error['code']}') : null;
      throw StremioApiException('$path: $error', code: code);
    }
    return payload['result'];
  }

  // ---------------------------------------------------------------- auth

  /// Starts the official device-link flow. Returns the code plus the
  /// approval URL to open in a browser.
  Future<StremioLinkCode> createLink() async {
    final response = await _http.get(Uri.parse('$_linkBase/create?type=Create')).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw StremioApiException('HTTP ${response.statusCode} on link create');
    final Object? payload;
    try {
      payload = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw StremioApiException('malformed JSON on link create: ${e.message}');
    }
    if (payload is! Map<String, dynamic>) throw StremioApiException('unexpected response shape on link create');
    final error = payload['error'];
    if (error != null) throw StremioApiException('link create: $error');
    final result = payload['result'];
    if (result is! Map<String, dynamic>) throw StremioApiException('link create returned no result');
    final code = result['code'];
    final link = result['link'];
    if (code is! String || code.isEmpty || link is! String || link.isEmpty) {
      throw StremioApiException('link create returned incomplete data');
    }
    return StremioLinkCode(code: code, link: link);
  }

  /// Polls a link code. Returns the account auth key once the user approves,
  /// or null while the code is still pending (Stremio error 101) — mirroring
  /// MDBridge, any error here is treated as "not approved yet".
  Future<String?> readLink(String code) async {
    try {
      final response = await _http
          .get(Uri.parse('$_linkBase/read?type=Read&code=${Uri.encodeComponent(code.trim().toUpperCase())}'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic>) return null;
      if (payload['error'] != null) return null;
      final result = payload['result'];
      if (result is! Map<String, dynamic>) return null;
      final authKey = result['authKey'];
      if (authKey is String && authKey.isNotEmpty) return authKey;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// True when [authKey] still resolves a Stremio user.
  Future<bool> validateAuthKey(String authKey) async {
    try {
      final result = await _post('getUser', {'type': 'GetUser', 'authKey': authKey});
      return result is Map<String, dynamic> && result['_id'] != null;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------ datastore

  /// Reads the given ids from the account's `libraryItem` collection.
  Future<List<Map<String, dynamic>>> getItems(String authKey, List<String> ids) async {
    final result = await _post('datastoreGet', {'authKey': authKey, 'collection': libraryCollection, 'ids': ids});
    if (result is! List) return const [];
    return result.whereType<Map<String, dynamic>>().toList();
  }

  /// Writes items back (batches of 100, matching the reference implementations).
  Future<void> putItems(String authKey, List<Map<String, dynamic>> changes) async {
    if (changes.isEmpty) return;
    for (var start = 0; start < changes.length; start += 100) {
      final batch = changes.sublist(start, start + 100 > changes.length ? changes.length : start + 100);
      final result = await _post('datastorePut', {
        'authKey': authKey,
        'collection': libraryCollection,
        'changes': batch,
      });
      if (result is! Map<String, dynamic> || result['success'] != true) {
        throw StremioApiException('datastorePut was not acknowledged');
      }
    }
  }

  // ------------------------------------------------------------- cinemeta

  /// Ordered episode ids (`tt…:season:episode`) for a series, from Cinemeta.
  /// Cached per imdb id for the process lifetime.
  Future<List<String>> seriesVideoIds(String imdb) async {
    final cached = _videoIdCache[imdb];
    if (cached != null) return cached;
    final response = await _http
        .get(Uri.parse('$_cinemetaBase/meta/series/$imdb.json'))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw StremioApiException('cinemeta HTTP ${response.statusCode} for $imdb');
    final payload = jsonDecode(response.body);
    final dynamic meta = (payload is Map<String, dynamic>) ? payload['meta'] : null;
    final videos = (meta is Map<String, dynamic>) ? meta['videos'] : null;
    if (videos is! List) throw StremioApiException('cinemeta returned no videos for $imdb');
    final parsed = videos.whereType<Map<String, dynamic>>().where((v) => v['id'] is String && (v['id'] as String).isNotEmpty).toList();
    parsed.sort((a, b) {
      final pa = _videoParts(a['id'] as String) ?? const (-1, -1);
      final pb = _videoParts(b['id'] as String) ?? const (-1, -1);
      if (pa.$1 != pb.$1) return pa.$1.compareTo(pb.$1);
      if (pa.$2 != pb.$2) return pa.$2.compareTo(pb.$2);
      return '${a['released'] ?? ''}'.compareTo('${b['released'] ?? ''}');
    });
    final ids = parsed.map((v) => v['id'] as String).toList(growable: false);
    _videoIdCache[imdb] = ids;
    return ids;
  }

  // ------------------------------------------------------------- progress

  /// Merges one playback-progress record into the account datastore,
  /// fetch-then-merge so unknown fields and unrelated items survive.
  ///
  /// [season]/[episode] are required for series. [markWatched] flips the
  /// watched state (movie play count / series bitfield).
  Future<void> pushProgress({
    required String authKey,
    required String imdb,
    required bool isEpisode,
    required String title,
    int? season,
    int? episode,
    required int positionMs,
    required int durationMs,
    required bool markWatched,
    required String nowIso,
  }) async {
    if (imdb.isEmpty || durationMs <= 0) return;
    final fetched = await getItems(authKey, [imdb]);
    final item = fetched.isNotEmpty
        ? Map<String, dynamic>.from(fetched.first)
        : _newItem(imdb: imdb, title: title, isEpisode: isEpisode, now: nowIso);
    final rawState = item['state'];
    final state = <String, dynamic>{
      ..._defaultState(),
      if (rawState is Map<String, dynamic>) ...rawState,
    };

    state['timeOffset'] = positionMs;
    state['duration'] = durationMs;
    state['lastWatched'] = nowIso;

    if (!isEpisode) {
      state['video_id'] = imdb;
      if (markWatched) {
        final times = int.tryParse('${state['timesWatched'] ?? 0}') ?? 0;
        state['timesWatched'] = times > 0 ? times : 1;
      }
    } else if (season != null && episode != null) {
      String videoId = '$imdb:$season:$episode';
      List<String> videoIds = const [];
      try {
        videoIds = await seriesVideoIds(imdb);
        for (final id in videoIds) {
          final parts = _videoParts(id);
          if (parts != null && parts.$1 == season && parts.$2 == episode) {
            videoId = id;
            break;
          }
        }
      } catch (_) {
        // Cinemeta unreachable — fall back to the canonical id and skip the
        // watched bitfield (progress still lands).
      }
      state['video_id'] = videoId;
      if (markWatched && videoIds.isNotEmpty) {
        final watched = decodeWatchedBitfield(state['watched'], videoIds)..add(videoId);
        state['watched'] = encodeWatchedBitfield(watched, videoIds);
      }
    }

    item['state'] = state;
    item['_mtime'] = nowIso;
    item.putIfAbsent('_ctime', () => nowIso);
    item.putIfAbsent('removed', () => false);
    item.putIfAbsent('temp', () => true);
    item.putIfAbsent('behaviorHints', () => <String, dynamic>{});
    item['name'] = item['name'] ?? title;
    item['type'] = item['type'] ?? (isEpisode ? 'series' : 'movie');

    await putItems(authKey, [item]);
  }

  Map<String, dynamic> _newItem({required String imdb, required String title, required bool isEpisode, required String now}) => {
    '_id': imdb,
    'name': title.isEmpty ? imdb : title,
    'type': isEpisode ? 'series' : 'movie',
    'poster': null,
    'posterShape': 'poster',
    'removed': false,
    'temp': true,
    '_ctime': now,
    '_mtime': now,
    'state': _defaultState(),
    'behaviorHints': <String, dynamic>{},
  };

  Map<String, dynamic> _defaultState() => {
    'lastWatched': null,
    'timeWatched': 0,
    'timeOffset': 0,
    'overallTimeWatched': 0,
    'timesWatched': 0,
    'flaggedWatched': 0,
    'duration': 0,
    'video_id': null,
    'watched': null,
    'noNotif': false,
  };
}

/// `(season, episode)` parsed from a `tt…:season:episode` id, or null.
(int, int)? _videoParts(String id) {
  final parts = id.split(':');
  if (parts.length < 3) return null;
  final season = int.tryParse(parts[parts.length - 2]);
  final episode = int.tryParse(parts[parts.length - 1]);
  if (season == null || episode == null) return null;
  return (season, episode);
}

/// Decodes Stremio's compressed watched-episode bitfield into the set of
/// watched video ids. Ported from MDBridge/Scrob (zlib + base64, anchored on
/// one known video id relative to Cinemeta's episode order).
Set<String> decodeWatchedBitfield(Object? serialized, List<String> videoIds) {
  final out = <String>{};
  final text = serialized is String ? serialized : '';
  if (text.isEmpty || videoIds.isEmpty) return out;

  final thirdColon = text.lastIndexOf(':');
  if (thirdColon < 0) return out;
  final encoded = text.substring(thirdColon + 1);
  final rest = text.substring(0, thirdColon);
  final secondColon = rest.lastIndexOf(':');
  if (secondColon < 0) return out;
  final anchor = rest.substring(0, secondColon);
  final anchorLen = int.tryParse(rest.substring(secondColon + 1));
  if (anchorLen == null) return out;
  final anchorIndex = videoIds.indexOf(anchor);
  if (anchorIndex < 0) return out;

  final List<int> packed;
  try {
    packed = ZLibCodec().decode(base64Decode(encoded));
  } catch (_) {
    return out;
  }

  final offset = (anchorLen - 1) - anchorIndex;
  for (var index = 0; index < videoIds.length; index++) {
    final oldIndex = index + offset;
    if (oldIndex < 0 || oldIndex >= anchorLen) continue;
    final byteIndex = oldIndex ~/ 8;
    final bitIndex = oldIndex % 8;
    if (byteIndex < packed.length && (packed[byteIndex] & (1 << bitIndex)) != 0) {
      out.add(videoIds[index]);
    }
  }
  return out;
}

/// Inverse of [decodeWatchedBitfield]. Callers guarantee [watchedIds] is
/// non-empty and a subset of [videoIds].
String? encodeWatchedBitfield(Set<String> watchedIds, List<String> videoIds) {
  if (videoIds.isEmpty || watchedIds.isEmpty) return null;
  final values = List<int>.filled((videoIds.length + 7) ~/ 8, 0);
  var lastIndex = 0;
  var matched = false;
  for (var index = 0; index < videoIds.length; index++) {
    if (!watchedIds.contains(videoIds[index])) continue;
    final byteIndex = index ~/ 8;
    final bitIndex = index % 8;
    values[byteIndex] |= 1 << bitIndex;
    lastIndex = index;
    matched = true;
  }
  if (!matched) return null;
  final compressed = base64Encode(ZLibCodec(level: 6).encode(values));
  return '${videoIds[lastIndex]}:${lastIndex + 1}:$compressed';
}
