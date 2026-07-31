import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';

/// A single candidate stream returned by an addon's `/stream` endpoint.
///
/// Torrent-backed addons return [infoHash] (+ optional [fileIndex]) for the
/// client to resolve via a debrid service. Some addons pre-configured with a
/// debrid API key (e.g. Torrentio+RD) instead return an already-resolved
/// [url] the app can play directly without any further resolution step.
class StremioStream {
  final String? url;
  final String? infoHash;
  final int? fileIndex;
  final String? title;
  final String? name;

  const StremioStream({this.url, this.infoHash, this.fileIndex, this.title, this.name});

  bool get isDirectUrl => url != null && url!.isNotEmpty;
  bool get isTorrent => infoHash != null && infoHash!.isNotEmpty;

  factory StremioStream.fromJson(Map<String, dynamic> json) {
    return StremioStream(
      url: json['url'] as String?,
      infoHash: json['infoHash'] as String?,
      fileIndex: (json['fileIdx'] as num?)?.toInt(),
      title: json['title'] as String?,
      name: json['name'] as String?,
    );
  }

  /// A magnet URI built from [infoHash], suitable for Real-Debrid's
  /// `/torrents/addMagnet`. Null when this isn't a torrent-backed stream.
  String? get magnetUri {
    final hash = infoHash;
    if (hash == null || hash.isEmpty) return null;
    return 'magnet:?xt=urn:btih:$hash${name != null ? '&dn=${Uri.encodeComponent(name!)}' : ''}';
  }
}

/// A single episode entry from a series meta response's `videos` array.
class StremioMetaVideo {
  final String id;
  final int? season;
  final int? episode;
  final String? title;
  final String? thumbnail;
  final String? overview;

  const StremioMetaVideo({required this.id, this.season, this.episode, this.title, this.thumbnail, this.overview});

  factory StremioMetaVideo.fromJson(Map<String, dynamic> json) {
    return StremioMetaVideo(
      id: json['id'] as String? ?? '',
      season: (json['season'] as num?)?.toInt(),
      episode: (json['episode'] as num?)?.toInt(),
      title: (json['title'] ?? json['name']) as String?,
      thumbnail: json['thumbnail'] as String?,
      overview: json['overview'] as String?,
    );
  }
}

/// Catalog/meta preview item — the shape returned by `/catalog` rows and
/// (for the top-level fields) `/meta` detail responses.
class StremioMetaPreview {
  final String id;
  final String type;
  final String? name;
  final String? poster;
  final String? background;
  final String? description;
  final int? releaseYear;
  final List<String>? genres;

  /// Episode list, present on a series' full `/meta` response only (never on
  /// catalog preview rows).
  final List<StremioMetaVideo>? videos;

  const StremioMetaPreview({
    required this.id,
    required this.type,
    this.name,
    this.poster,
    this.background,
    this.description,
    this.releaseYear,
    this.genres,
    this.videos,
  });

  factory StremioMetaPreview.fromJson(Map<String, dynamic> json) {
    final releaseInfo = json['releaseInfo'] as String?;
    final rawVideos = json['videos'] as List?;
    return StremioMetaPreview(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'movie',
      name: json['name'] as String?,
      poster: json['poster'] as String?,
      background: json['background'] as String?,
      description: json['description'] as String?,
      releaseYear: releaseInfo != null ? int.tryParse(releaseInfo.split(RegExp(r'[-–]')).first.trim()) : null,
      genres: (json['genres'] as List?)?.map((e) => e.toString()).toList(),
      videos: rawVideos?.whereType<Map<String, dynamic>>().map(StremioMetaVideo.fromJson).toList(),
    );
  }
}

/// Thrown when an addon responds with something other than a well-formed
/// manifest/catalog/meta/stream payload.
class StremioAddonException implements Exception {
  final String message;
  const StremioAddonException(this.message);
  @override
  String toString() => 'StremioAddonException: $message';
}

/// Thin client for the Stremio addon protocol.
///
/// Plain HTTP/JSON against a single addon's base URL -- no Stremio
/// app/binary involved. Protocol reference:
/// https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md
class StremioAddonClient {
  final String addonUrl;
  final http.Client _http;

  StremioAddonClient({required String addonUrl, http.Client? httpClient})
    : addonUrl = _normalizeBaseUrl(addonUrl),
      _http = httpClient ?? http.Client();

  static String _normalizeBaseUrl(String url) {
    // Copy-pasting a long config string (common for Torrentio-style addons)
    // can pick up stray whitespace from how it was displayed/wrapped. URLs
    // never legitimately contain literal spaces/newlines/tabs here.
    var normalized = url.trim().replaceAll(RegExp(r'\s+'), '');
    if (normalized.endsWith('/manifest.json')) {
      normalized = normalized.substring(0, normalized.length - '/manifest.json'.length);
    }
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    // {addonUrl}/configure is the addon's settings *page* (HTML), not the
    // manifest URL -- easy to copy by mistake since Torrentio's own site
    // doesn't clearly distinguish the two.
    if (normalized.endsWith('/configure')) {
      normalized = normalized.substring(0, normalized.length - '/configure'.length);
    }
    return normalized;
  }

  /// Redact the config segment of a Torrentio-style addon URL before it
  /// reaches an exception message, log line, or crash report. These addons
  /// embed the Real-Debrid API token directly in the URL path (there's no
  /// separate auth header to redact instead), so the raw URL must never be
  /// surfaced anywhere it could be screenshotted, logged, or sent to Sentry.
  static String _redactForDisplay(Uri uri) {
    final segments = uri.pathSegments;
    final lastSegment = segments.isEmpty ? '' : segments.last;
    return '${uri.scheme}://${uri.host}/•••/$lastSegment';
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final uri = Uri.parse('$addonUrl$path');
    final http.Response response;
    try {
      response = await _http.get(uri).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StremioAddonException('Timed out reaching ${_redactForDisplay(uri)}');
    }
    if (response.statusCode != 200) {
      throw StremioAddonException('HTTP ${response.statusCode} for ${_redactForDisplay(uri)}');
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const StremioAddonException('Expected a JSON object response');
      }
      return decoded;
    } on FormatException catch (e) {
      throw StremioAddonException('Malformed JSON from ${_redactForDisplay(uri)}: $e');
    }
  }

  /// Fetch and validate the addon's manifest. Throws [StremioAddonException]
  /// if the addon is unreachable or doesn't advertise the minimal fields
  /// (`id`, `name`, `resources`) every addon must have.
  Future<Map<String, dynamic>> fetchManifest() async {
    final manifest = await _getJson('/manifest.json');
    if (manifest['id'] == null || manifest['resources'] == null) {
      throw const StremioAddonException('Response is missing required manifest fields (id, resources)');
    }
    return manifest;
  }

  /// Browse a catalog. [type] is `movie`/`series`/etc; [id] is the catalog id
  /// from the manifest's `catalogs` list. [extra] carries protocol query
  /// params like `skip`/`search`/`genre`, appended as `/key=value` segments.
  Future<List<StremioMetaPreview>> fetchCatalog(String type, String id, {Map<String, String>? extra}) async {
    var path = '/catalog/${Uri.encodeComponent(type)}/${Uri.encodeComponent(id)}';
    if (extra != null && extra.isNotEmpty) {
      final extraSegment = extra.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
      path += '/$extraSegment';
    }
    path += '.json';
    final json = await _getJson(path);
    final metas = json['metas'] as List?;
    if (metas == null) return const [];
    return metas.whereType<Map<String, dynamic>>().map(StremioMetaPreview.fromJson).toList();
  }

  /// Fetch full detail for a single item.
  Future<StremioMetaPreview?> fetchMeta(String type, String id) async {
    final json = await _getJson('/meta/${Uri.encodeComponent(type)}/${Uri.encodeComponent(id)}.json');
    final meta = json['meta'] as Map<String, dynamic>?;
    if (meta == null) return null;
    return StremioMetaPreview.fromJson(meta);
  }

  /// Candidate streams for a playable item. For series episodes, [id] is
  /// `{imdbId}:{season}:{episode}` per protocol convention.
  Future<List<StremioStream>> fetchStreams(String type, String id) async {
    try {
      final json = await _getJson('/stream/${Uri.encodeComponent(type)}/${Uri.encodeComponent(id)}.json');
      final streams = json['streams'] as List?;
      if (streams == null) return const [];
      return streams.whereType<Map<String, dynamic>>().map(StremioStream.fromJson).toList();
    } on StremioAddonException catch (e) {
      appLogger.w('Stremio stream fetch failed for $type/$id', error: e);
      return const [];
    }
  }

  void close() => _http.close();
}
