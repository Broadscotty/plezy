import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';

/// Thrown for any Real-Debrid API failure (bad token, rate limit, torrent
/// stuck in an error state, etc).
class RealDebridException implements Exception {
  final String message;
  const RealDebridException(this.message);
  @override
  String toString() => 'RealDebridException: $message';
}

/// Thin client for the subset of the Real-Debrid REST API needed to turn a
/// magnet/infoHash into a direct, playable HTTPS link. Same API surface
/// Unchained already uses against a user's existing RD account.
///
/// https://api.real-debrid.com/rest/1.0
class RealDebridClient {
  static const _baseUrl = 'https://api.real-debrid.com/rest/1.0';

  final String apiToken;
  final http.Client _http;

  RealDebridClient({required this.apiToken, http.Client? httpClient}) : _http = httpClient ?? http.Client();

  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $apiToken'};

  void _throwIfError(http.Response response, String action) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw RealDebridException('Real-Debrid rejected the API token ($action)');
    }
    throw RealDebridException('Real-Debrid $action failed: HTTP ${response.statusCode}');
  }

  /// Add a magnet link, returning the new torrent's Real-Debrid id.
  Future<String> addMagnet(String magnetUri) async {
    final response = await _http
        .post(Uri.parse('$_baseUrl/torrents/addMagnet'), headers: _authHeaders, body: {'magnet': magnetUri})
        .timeout(const Duration(seconds: 15));
    _throwIfError(response, 'addMagnet');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final id = json['id'] as String?;
    if (id == null) throw const RealDebridException('addMagnet response missing torrent id');
    return id;
  }

  /// Torrent status/file listing for [torrentId].
  Future<Map<String, dynamic>> torrentInfo(String torrentId) async {
    final response = await _http
        .get(Uri.parse('$_baseUrl/torrents/info/$torrentId'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    _throwIfError(response, 'torrentInfo');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Select which files within the torrent should be downloaded. Real-Debrid
  /// requires this before it will fetch/cache the torrent at all.
  Future<void> selectFiles(String torrentId, {List<String>? fileIds}) async {
    final response = await _http
        .post(
          Uri.parse('$_baseUrl/torrents/selectFiles/$torrentId'),
          headers: _authHeaders,
          body: {'files': (fileIds == null || fileIds.isEmpty) ? 'all' : fileIds.join(',')},
        )
        .timeout(const Duration(seconds: 15));
    // Real-Debrid returns 204 with no body on success.
    if (response.statusCode != 204 && response.statusCode != 200) {
      _throwIfError(response, 'selectFiles');
    }
  }

  /// Resolve a Real-Debrid-hosted link (from a torrent's `links` array) to a
  /// direct, unrestricted HTTPS URL the player/downloader can fetch.
  Future<String> unrestrictLink(String link) async {
    final response = await _http
        .post(Uri.parse('$_baseUrl/unrestrict/link'), headers: _authHeaders, body: {'link': link})
        .timeout(const Duration(seconds: 15));
    _throwIfError(response, 'unrestrictLink');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final download = json['download'] as String?;
    if (download == null) throw const RealDebridException('unrestrictLink response missing download URL');
    return download;
  }

  /// Add a magnet, select the largest file, wait for it to finish caching
  /// (or return immediately if it was already cached), and return a direct
  /// playable link.
  ///
  /// Polls at [pollInterval] up to [pollTimeout] total. Throws
  /// [RealDebridException] if the torrent errors out or doesn't finish
  /// within the timeout.
  Future<String> resolveMagnetToDirectLink(
    String magnetUri, {
    Duration pollInterval = const Duration(seconds: 3),
    Duration pollTimeout = const Duration(minutes: 5),
  }) async {
    final torrentId = await addMagnet(magnetUri);

    var info = await torrentInfo(torrentId);
    if (info['status'] == 'waiting_files_selection') {
      final files = (info['files'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
      final largest = _largestFile(files);
      await selectFiles(torrentId, fileIds: largest != null ? [largest['id'].toString()] : null);
      info = await torrentInfo(torrentId);
    }

    final deadline = DateTime.now().add(pollTimeout);
    while (info['status'] != 'downloaded') {
      final status = info['status'] as String?;
      if (status == 'error' || status == 'magnet_error' || status == 'virus' || status == 'dead') {
        throw RealDebridException('Real-Debrid torrent entered status "$status"');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const RealDebridException('Timed out waiting for Real-Debrid to cache this torrent');
      }
      await Future<void>.delayed(pollInterval);
      info = await torrentInfo(torrentId);
    }

    final links = (info['links'] as List?)?.whereType<String>().toList() ?? const [];
    if (links.isEmpty) throw const RealDebridException('Real-Debrid torrent finished with no links');
    appLogger.d('Real-Debrid torrent $torrentId ready, unrestricting ${links.first}');
    return unrestrictLink(links.first);
  }

  Map<String, dynamic>? _largestFile(List<Map<String, dynamic>> files) {
    if (files.isEmpty) return null;
    Map<String, dynamic>? largest;
    var largestBytes = -1;
    for (final file in files) {
      final bytes = (file['bytes'] as num?)?.toInt() ?? 0;
      if (bytes > largestBytes) {
        largestBytes = bytes;
        largest = file;
      }
    }
    return largest;
  }

  void close() => _http.close();
}
