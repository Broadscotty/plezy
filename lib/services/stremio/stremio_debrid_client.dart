import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../../exceptions/media_server_exceptions.dart';
import '../../i18n/strings.g.dart';
import '../../media/download_resolution.dart';
import '../../media/episode_collection.dart';
import '../../media/ids.dart';
import '../../media/library_filter_result.dart';
import '../../media/library_first_character.dart';
import '../../media/library_query.dart';
import '../../media/live_tv_support.dart';
import '../../media/lyrics.dart';
import '../../media/media_backend.dart';
import '../../media/media_file_info.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_playlist.dart';
import '../../media/media_server_client.dart';
import '../../media/media_sort.dart';
import '../../media/media_source_info.dart';
import '../../media/media_version.dart';
import '../../media/playback_report_metadata.dart';
import '../../media/server_capabilities.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../../utils/media_server_http_client.dart' show AbortController;
import '../api_cache.dart';
import '../playback_initialization_types.dart';
import '../scrub_preview_source.dart';
import 'debrid_api_cache.dart';
import 'real_debrid_client.dart';
import 'stremio_addon_client.dart';

/// Composite item id used for debrid `MediaItem`s: `{stremioType}|{stremioId}`.
/// Kept as a plain string (rather than a new field on [MediaItem]) since the
/// interface passes ids as bare strings everywhere.
class StremioItemId {
  final String type;
  final String stremioId;
  const StremioItemId(this.type, this.stremioId);

  @override
  String toString() => '$type|$stremioId';

  static StremioItemId parse(String id) {
    final parts = id.split('|');
    if (parts.length != 2) {
      throw ArgumentError('Malformed Stremio item id: $id');
    }
    return StremioItemId(parts[0], parts[1]);
  }
}

/// No-op [LiveTvSupport] for backends that don't have it. [isAvailable]
/// always returns false; well-behaved callers check that before calling
/// anything else on this interface, per its own documented contract.
class NoLiveTvSupport implements LiveTvSupport {
  const NoLiveTvSupport();

  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Live TV is not supported for this backend (isAvailable() is false)');
}

Never _unsupported(String what) => throw UnsupportedError('$what is not supported for the debrid backend');

/// Catalog descriptor as advertised by an addon manifest, plus which addon
/// serves it. Meta/search/catalog fetches must go to the owning addon:
/// Cinemeta only resolves `tt...` IMDb ids, stream addons like Formulio
/// only resolve their own id space (e.g. `hpy...`).
typedef _StremioCatalog = ({
  String type,
  String id,
  String name,
  bool fromStreamAddon,
  Set<String> supportedExtras,
});

/// [MediaServerClient] backed by a single Stremio addon, resolving streams
/// through Real-Debrid rather than a live media server.
class StremioDebridClient extends MediaServerClient {
  @override
  final ServerId serverId;
  @override
  final String? serverName;

  final StremioAddonClient _streamAddon;
  final StremioAddonClient _catalogAddon;
  final RealDebridClient _realDebrid;

  /// Catalog descriptor as advertised by an addon manifest, plus which addon
  /// serves it. Meta/search/catalog fetches must go to the owning addon:
  /// Cinemeta only resolves `tt...` IMDb ids, stream addons like Formulio
  /// only resolve their own id space (e.g. `hpy...`).
  bool _offlineMode = false;

  /// Merged catalog list: stream addon catalogs first, then Cinemeta's
  /// browsable `top` catalogs. Populated lazily on first catalog use.
  List<_StremioCatalog>? _catalogs;

  /// The stream addon's manifest, parsed once for its display name, catalogs,
  /// and meta capabilities. Null = not loaded yet; an empty map marks a
  /// load that already failed (don't retry every call).
  Map<String, dynamic>? _streamManifest;

  /// Display name from the stream addon manifest (e.g. "Formulio"), used as
  /// the library server label. Never the raw addon URL -- Torrentio-style
  /// URLs embed the Real-Debrid API token in the path.
  String? _streamAddonName;

  /// Id prefixes and types the stream addon's `meta` resource serves, from
  /// its manifest `resources` (e.g. Formulio: prefixes {hpy}, types {series}).
  /// Empty prefixes/types mean "no restriction" per the addon protocol.
  bool _hasStreamMetaResource = false;
  Set<String> _streamMetaIdPrefixes = const {};
  Set<String> _streamMetaTypes = const {};

  /// Stremio's own official metadata/catalog addon. Used for browsing and
  /// item detail regardless of which stream addon the user configured --
  /// Torrentio-style addons only provide streams, not catalogs, same as in
  /// real Stremio where Cinemeta is what actually populates Discover/Board.
  static const _cinemetaUrl = 'https://v3-cinemeta.strem.io/manifest.json';

  StremioDebridClient({
    required this.serverId,
    required String addonUrl,
    required String realDebridApiToken,
    this.serverName,
    @visibleForTesting http.Client? httpClient,
  }) : _streamAddon = StremioAddonClient(addonUrl: addonUrl, httpClient: httpClient),
       _catalogAddon = StremioAddonClient(addonUrl: _cinemetaUrl, httpClient: httpClient),
       _realDebrid = RealDebridClient(apiToken: realDebridApiToken);

  @override
  MediaBackend get backend => MediaBackend.debrid;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.debrid;

  @override
  ApiCache get cache => DebridApiCache.instance;

  @override
  bool get isOfflineMode => _offlineMode;

  @override
  void setOfflineMode(bool offline) => _offlineMode = offline;

  @override
  void close() {
    _streamAddon.close();
    _catalogAddon.close();
    _realDebrid.close();
  }

  @override
  Future<HealthStatus> checkHealth() async {
    try {
      // Check the addon the user actually configured (the stream provider) --
      // that's the one whose validity matters to them, since the catalog
      // addon (Cinemeta) is fixed and always assumed reachable.
      await _streamAddon.fetchManifest();
      return HealthStatus.online;
    } on StremioAddonException catch (e) {
      appLogger.w('Stremio addon health check failed', error: e);
      return HealthStatus.offline;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async => serverId.toString();

  /// Fetch and cache the stream addon's manifest, extracting its display
  /// name and `meta` resource capabilities (id prefixes / types). Safe to
  /// call repeatedly; a failed load is remembered as an empty manifest so
  /// every subsequent call doesn't re-hit the network.
  Future<void> _ensureStreamAddonInfo() async {
    final cached = _streamManifest;
    if (cached != null) return;
    Map<String, dynamic> manifest;
    try {
      manifest = await _streamAddon.fetchManifest();
    } on StremioAddonException catch (e) {
      appLogger.d('Stremio: stream addon manifest unavailable: $e');
      manifest = const {};
    }
    _streamManifest = manifest;
    _streamAddonName = manifest['name'] as String?;
    final prefixes = <String>{};
    final types = <String>{};
    var hasMeta = false;
    for (final resource in manifest['resources'] as List? ?? const []) {
      if (resource is! Map<String, dynamic>) continue;
      if (resource['name'] != 'meta') continue;
      hasMeta = true;
      prefixes.addAll((resource['idPrefixes'] as List?)?.whereType<String>() ?? const <String>[]);
      types.addAll((resource['types'] as List?)?.whereType<String>() ?? const <String>[]);
    }
    _hasStreamMetaResource = hasMeta;
    _streamMetaIdPrefixes = prefixes;
    _streamMetaTypes = types;
  }

  /// Whether the stream addon's `meta` resource covers [id] for [type]. An
  /// addon without a parsed manifest (unreachable) or without a declared
  /// `meta` resource (Torrentio, etc.) serves nothing here -- callers
  /// fall through to Cinemeta.
  bool _streamAddonServesMeta(String type, String id) {
    if (_streamManifest == null || _streamManifest!.isEmpty) return false;
    if (!_hasStreamMetaResource) return false;
    if (_streamMetaTypes.isNotEmpty && !_streamMetaTypes.contains(type)) return false;
    if (_streamMetaIdPrefixes.isEmpty) return true;
    return _streamMetaIdPrefixes.any(id.startsWith);
  }

  /// Whether Cinemeta can plausibly serve [id] for [type] -- IMDb-prefixed
  /// movie/series ids only, per its manifest (`idPrefixes: ["tt"]`).
  bool _catalogAddonServesMeta(String type, String id) => id.startsWith('tt') && (type == 'movie' || type == 'series');

  /// Fetch show-level meta from the addon that owns [stremioId], falling
  /// back to the other addon when the preferred one can't resolve it.
  /// Routing by declared id prefixes is what makes non-IMDb addons (e.g.
  /// Formulio's `hpy...` ids) work at all -- Cinemeta 404s on those.
  Future<StremioMetaPreview?> _fetchShowMeta(String type, String stremioId) async {
    final showId = _splitShowVideoId(stremioId).showId;
    await _ensureStreamAddonInfo();
    final streamFirst = _streamAddonServesMeta(type, showId);
    final primary = streamFirst ? _streamAddon : _catalogAddon;
    final secondaryServes = streamFirst ? _catalogAddonServesMeta(type, showId) : _streamAddonServesMeta(type, showId);
    final secondary = streamFirst ? _catalogAddon : _streamAddon;
    try {
      final meta = await primary.fetchMeta(type, showId);
      if (meta != null || !secondaryServes) return meta;
    } on StremioAddonException catch (e) {
      if (!secondaryServes) rethrow;
      appLogger.d('Stremio: meta fetch failed on preferred addon, trying fallback: $e');
    }
    return secondary.fetchMeta(type, showId);
  }

  /// Load the merged catalog list: the stream addon's own catalogs first
  /// (the content the user actually configured), then Cinemeta's generically
  /// browsable `top` catalogs. Deduped by `type|id`, stream addon winning.
  ///
  /// Only Cinemeta's "top" is kept from the fallback side: its other catalogs
  /// either require parameters only Stremio's own app supplies internally
  /// (New/year needs a required genre; Last videos/Calendar videos need
  /// specific show-id lists for episode-release tracking, not general
  /// browsing) or would multiply into several near-duplicate library entries
  /// per type. Stream addon catalogs are taken as declared -- their addon
  /// owns them and knows what's browsable.
  Future<List<_StremioCatalog>> _loadCatalogs() async {
    final cached = _catalogs;
    if (cached != null) return cached;

    await _ensureStreamAddonInfo();
    final catalogs = <_StremioCatalog>[];

    // 1. Stream addon catalogs.
    final rawStream = _streamManifest?['catalogs'] as List? ?? const [];
    for (final c in rawStream.whereType<Map<String, dynamic>>()) {
      final id = c['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final extras = (c['extra'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((e) => e['name'] as String? ?? '')
          .where((name) => name.isNotEmpty)
          .toSet();
      catalogs.add((
        type: c['type'] as String? ?? 'movie',
        id: id,
        name: c['name'] as String? ?? (id.isNotEmpty ? id : 'Catalog'),
        fromStreamAddon: true,
        supportedExtras: extras,
      ));
    }
    if (catalogs.isNotEmpty) {
      appLogger.i('Stremio: using stream addon catalogs: ${catalogs.map((c) => c.name).join(", ")}');
    }

    // 2. Cinemeta's top catalogs (generic movie/series browsing), skipping
    //    any (type, id) the stream addon already provides. Always included
    //    so every debrid connection has browsable Movies/TV Shows — the
    //    user can hide ones they don't want via the library management sheet.
    try {
      final manifest = await _catalogAddon.fetchManifest();
      final rawCatalogs = manifest['catalogs'] as List? ?? const [];
      for (final c in rawCatalogs.whereType<Map<String, dynamic>>()) {
        final id = c['id'] as String? ?? '';
        final type = c['type'] as String? ?? 'movie';
        if (id != 'top') continue;
        if (catalogs.any((existing) => existing.type == type && existing.id == id)) continue;
        catalogs.add((
          type: type,
          id: id,
          name: c['name'] as String? ?? (id.isNotEmpty ? id : 'Catalog'),
          fromStreamAddon: false,
          supportedExtras: const {'skip', 'search', 'genre'},
        ));
      }
    } on StremioAddonException catch (e) {
      if (catalogs.isEmpty) rethrow;
      appLogger.w('Stremio: Cinemeta catalogs unavailable, using stream addon catalogs only', error: e);
    }

    _catalogs = catalogs;
    return catalogs;
  }

  MediaItem _mapPreviewToItem(StremioMetaPreview preview) {
    final kind = preview.type == 'series' ? MediaKind.show : MediaKind.movie;
    return MediaItem(
      id: StremioItemId(preview.type, preview.id).toString(),
      backend: MediaBackend.debrid,
      kind: kind,
      title: preview.name,
      summary: preview.description,
      year: preview.releaseYear,
      thumbPath: preview.poster,
      artPath: preview.background,
      genres: preview.genres,
      serverId: serverId.toString(),
      serverName: serverName,
      raw: {'stremioType': preview.type, 'stremioId': preview.id, 'addonUrl': _streamAddon.addonUrl},
    );
  }

  /// Label for the server chip on a library: the stream addon's manifest
  /// name for its own catalogs ("Formulio"), "Stremio" for the fixed
  /// Cinemeta catalogs. Host-only fallback -- never the full addon URL,
  /// which can embed the Real-Debrid API token.
  String get _streamAddonLabel {
    final name = _streamAddonName;
    if (name != null && name.isNotEmpty) return name;
    try {
      final host = Uri.parse(_streamAddon.addonUrl).host;
      if (host.isNotEmpty) return host;
    } catch (_) {}
    return 'Stremio';
  }

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    final catalogs = await _loadCatalogs();
    return [
      for (final catalog in catalogs)
        MediaLibrary(
          id: '${catalog.type}|${catalog.id}',
          backend: MediaBackend.debrid,
          // Stream addon catalogs use their own declared name (e.g.
          // "Formulio"); Cinemeta's two `top` catalogs are both literally
          // named "Popular", so keep the clearer generic titles there.
          title: catalog.fromStreamAddon ? catalog.name : (catalog.type == 'series' ? 'TV Shows' : 'Movies'),
          kind: catalog.type == 'series' ? MediaKind.show : MediaKind.movie,
          serverId: serverId.toString(),
          serverName: catalog.fromStreamAddon ? _streamAddonLabel : 'Stremio',
        ),
    ];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryContent(String libraryId, LibraryQuery query) =>
      fetchLibraryPagedContent(libraryId, query: query);

  /// The addon serving [type]/[catalogId] -- the stream addon when the
  /// catalog came from its manifest, Cinemeta otherwise. Unknown/stale
  /// library ids default to Cinemeta, the historical behavior.
  Future<StremioAddonClient> _catalogAddonFor(String type, String catalogId) async {
    final catalogs = await _loadCatalogs();
    for (final catalog in catalogs) {
      if (catalog.type == type && catalog.id == catalogId) {
        return catalog.fromStreamAddon ? _streamAddon : _catalogAddon;
      }
    }
    return _catalogAddon;
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    final parts = libraryId.split('|');
    if (parts.length != 2) {
      throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Malformed debrid library id: $libraryId');
    }
    final skip = query.offset;
    try {
      final addon = await _catalogAddonFor(parts[0], parts[1]);
      final catalogs = await _loadCatalogs();
      final catalog = catalogs.firstWhere(
        (c) => c.type == parts[0] && c.id == parts[1],
        orElse: () => (type: parts[0], id: parts[1], name: '', fromStreamAddon: false, supportedExtras: const {'skip'}),
      );
      final extra = <String, String>{};
      if (catalog.supportedExtras.contains('skip')) extra['skip'] = skip.toString();
      final previews = await addon.fetchCatalog(parts[0], parts[1], extra: extra.isEmpty ? null : extra);
      final items = previews.map(_mapPreviewToItem).toList();
      return LibraryPage(items: items, totalCount: fallbackPageTotal(offset: skip, itemCount: items.length), offset: skip);
    } on StremioAddonException {
      rethrow;
    } catch (e) {
      throw StremioAddonException('Unexpected error loading catalog (${e.runtimeType})');
    }
  }

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async =>
      LibraryFilterResult.empty;

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => const [];

  @override
  Future<List<LibraryFirstCharacter>> fetchFirstCharacters(String libraryId, {Map<String, String>? filters}) async =>
      const [];

  @override
  Future<void> refreshLibraryMetadata(String libraryId) async {}

  /// Split a Cinemeta-style item id into its show id and optional
  /// season/episode suffix. Show ids are bare (`tt1234567`); episode ids carry
  /// `{show}:{season}:{episode}` and season ids `{show}:{season}` per the
  /// Stremio video-id convention. Cinemeta's /meta endpoint only serves
  /// show-level meta, so any suffix must be stripped before the meta fetch
  /// and the flat `videos` array filtered client-side.
  static ({String showId, int? season, int? episode}) _splitShowVideoId(String id) {
    final parts = id.split(':');
    final showId = parts.first;
    final season = parts.length > 1 ? int.tryParse(parts[1]) : null;
    final episode = parts.length > 2 ? int.tryParse(parts[2]) : null;
    return (showId: showId, season: season, episode: episode);
  }

  /// Map a [StremioMetaVideo] (an episode row inside a show's meta) to a
  /// debrid [MediaItem], wiring the parent/season/grandparent hierarchy the
  /// detail screen and episode queue depend on.
  MediaItem _mapEpisode(
    StremioMetaPreview meta,
    StremioMetaVideo video, {
    required String stremioType,
    required String showId,
    required String seasonId,
  }) {
    return MediaItem(
      id: StremioItemId(stremioType, video.id).toString(),
      backend: MediaBackend.debrid,
      kind: MediaKind.episode,
      title: video.title,
      summary: video.overview,
      index: video.episode,
      parentIndex: video.season,
      parentId: seasonId,
      grandparentId: StremioItemId(stremioType, showId).toString(),
      grandparentTitle: meta.name,
      parentTitle: meta.name,
      thumbPath: video.thumbnail ?? meta.poster,
      serverId: serverId.toString(),
      serverName: serverName,
      raw: {'stremioType': stremioType, 'stremioId': video.id, 'addonUrl': _streamAddon.addonUrl},
    );
  }

  /// Resolve [id] (`show`, `season`, or `episode` scoped) to a [MediaItem]
  /// with playable versions. Show/movie ids map the preview; season ids build
  /// a synthetic season row over the flat videos list; episode ids find the
  /// matching video. Streams are always fetched with the FULL id — stream
  /// addons expect `{show}:{season}:{episode}`, never the bare show id.
  @override
  Future<MediaItem?> fetchItem(String id) async {
    final parsed = StremioItemId.parse(id);
    final split = _splitShowVideoId(parsed.stremioId);
    final meta = await _fetchShowMeta(parsed.type, parsed.stremioId);
    if (meta == null) return null;

    MediaItem item;
    if (split.episode != null && split.season != null) {
      final video = meta.videos?.where((v) => v.season == split.season && v.episode == split.episode).firstOrNull;
      if (video == null) return null;
      item = _mapEpisode(
        meta,
        video,
        stremioType: parsed.type,
        showId: split.showId,
        seasonId: StremioItemId(parsed.type, '${split.showId}:${split.season}').toString(),
      );
    } else if (split.season != null) {
      final seasonVideos = meta.videos?.where((video) => video.season == split.season) ?? const <StremioMetaVideo>[];
      if (seasonVideos.isEmpty) return null;
      item = MediaItem(
        id: StremioItemId(parsed.type, '${split.showId}:${split.season}').toString(),
        backend: MediaBackend.debrid,
        kind: MediaKind.season,
        title: t.common.seasonNumber(number: split.season!),
        parentTitle: meta.name,
        index: split.season,
        leafCount: seasonVideos.length,
        parentId: StremioItemId(parsed.type, split.showId).toString(),
        grandparentId: StremioItemId(parsed.type, split.showId).toString(),
        thumbPath: meta.poster,
        artPath: meta.background,
        serverId: serverId.toString(),
        serverName: serverName,
        raw: {'stremioType': parsed.type, 'stremioId': '${split.showId}:${split.season}', 'addonUrl': _streamAddon.addonUrl},
      );
    } else {
      item = _mapPreviewToItem(meta);
    }

    final versions = await _streamsToVersions(parsed.type, parsed.stremioId);
    final resolved = versions.isEmpty ? item : item.copyWith(mediaVersions: versions);
    // Nothing else writes to the metadata cache for this backend -- without
    // this, every downstream lookup (download completion, the Movies
    // download section grouping by cached metadata, etc.) is a permanent
    // cache miss.
    await cache.put(serverId, id, resolved.toJson());
    return resolved;
  }

  /// Map an item's candidate streams to [MediaVersion]s so Plezy's existing
  /// version-picker (already shown for any item with more than one version)
  /// lets the user choose a specific release/quality, the same way the
  /// Stremio app itself prompts for a file/source before playing.
  Future<List<MediaVersion>> _streamsToVersions(String stremioType, String stremioId) async {
    final streams = await _streamAddon.fetchStreams(stremioType, stremioId);
    return [
      for (var i = 0; i < streams.length; i++)
        MediaVersion(id: i.toString(), name: streams[i].title ?? streams[i].name ?? 'Source ${i + 1}', parts: const []),
    ];
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(String id) async =>
      (item: await fetchItem(id), onDeckEpisode: null);

  /// Return a show's SEASONS (grouped from the flat video list) or a single
  /// season's episodes when [parentId] is season-scoped. The detail screen
  /// drives season tabs from this list, exactly like Plex/Jellyfin.
  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    final parsed = StremioItemId.parse(parentId);
    final split = _splitShowVideoId(parsed.stremioId);
    final meta = await _fetchShowMeta(parsed.type, parsed.stremioId);
    final videos = meta?.videos;
    if (videos == null || videos.isEmpty) return const [];

    // Season-scoped parent: return that season's episodes.
    if (split.season != null) {
      final seasonId = parentId;
      final episodes = videos
          .where((video) => video.season == split.season)
          .map((video) => _mapEpisode(meta!, video, stremioType: parsed.type, showId: split.showId, seasonId: seasonId))
          .toList()
        ..sort((a, b) => (a.index ?? 0).compareTo(b.index ?? 0));
      for (final episode in episodes) {
        await cache.put(serverId, episode.id, episode.toJson());
      }
      return episodes;
    }

    // Show-scoped parent: group videos into season rows so the detail screen
    // shows season tabs instead of one flattened mega-list.
    final bySeason = <int, List<StremioMetaVideo>>{};
    for (final video in videos) {
      bySeason.putIfAbsent(video.season ?? 0, () => []).add(video);
    }
    final seasons = bySeason.entries.map((entry) {
      final seasonNumber = entry.key;
      final seasonVideos = entry.value;
      return MediaItem(
        id: StremioItemId(parsed.type, '${split.showId}:$seasonNumber').toString(),
        backend: MediaBackend.debrid,
        kind: MediaKind.season,
        // Season tabs/chips render `title` directly — show "Season N", not
        // the show name (which displayTitle still prefers via parentTitle).
        title: t.common.seasonNumber(number: seasonNumber),
        parentTitle: meta?.name,
        index: seasonNumber,
        leafCount: seasonVideos.length,
        parentId: parentId,
        grandparentId: parentId,
        thumbPath: meta?.poster,
        artPath: meta?.background,
        serverId: serverId.toString(),
        serverName: serverName,
        raw: {
          'stremioType': parsed.type,
          'stremioId': '${split.showId}:$seasonNumber',
          'addonUrl': _streamAddon.addonUrl,
        },
      );
    }).toList()
      ..sort((a, b) => (a.index ?? 0).compareTo(b.index ?? 0));
    for (final season in seasons) {
      await cache.put(serverId, season.id, season.toJson());
    }
    return seasons;
  }

  @override
  Future<List<MediaItem>> fetchLibraryFolders(String libraryId, {void Function(List<MediaItem> itemsSoFar)? onPage}) =>
      _unsupported('fetchLibraryFolders');

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) => _unsupported('fetchFolderChildren');

  /// Page a season's episodes (or, for a show-scoped id, ALL episodes across
  /// every season — the flattened "episodes directly" view). Uses the same
  /// in-memory filter over the show's flat video list as [fetchChildren].
  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final parsed = StremioItemId.parse(parentId);
    final split = _splitShowVideoId(parsed.stremioId);
    final meta = await _fetchShowMeta(parsed.type, parsed.stremioId);
    final videos = meta?.videos ?? const <StremioMetaVideo>[];
    final filtered = (split.season == null
            ? videos
            : videos.where((video) => video.season == split.season))
        .toList()
      ..sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));

    final offset = start ?? 0;
    final pageSize = size ?? filtered.length;
    final slice = filtered.skip(offset).take(pageSize).toList();
    final episodes = [
      for (final video in slice)
        _mapEpisode(
          meta!,
          video,
          stremioType: parsed.type,
          showId: split.showId,
          seasonId: split.season == null
              ? parentId
              : StremioItemId(parsed.type, '${split.showId}:${split.season}').toString(),
        ),
    ];
    for (final episode in episodes) {
      await cache.put(serverId, episode.id, episode.toJson());
    }
    return LibraryPage(items: episodes, totalCount: filtered.length, offset: offset);
  }

  /// Flattened episodes for "play all"/"download all"/queue flows — the same
  /// flat list Plex serves via /grandchildren.
  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) => fetchChildrenPage(parentId, start: start, size: size, abort: abort);

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    final page = await fetchPlayableDescendantsPage(parentId);
    return page.items;
  }

  /// Client-side episode queue for prev/next/up-next: all episodes of the
  /// series in aired order, built from the show meta's flat video list.
  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async {
    final parsed = StremioItemId.parse(seriesId);
    final meta = await _fetchShowMeta(parsed.type, parsed.stremioId);
    final videos = meta?.videos;
    if (videos == null || videos.isEmpty) return null;
    final episodes = videos
        .map(
          (video) => _mapEpisode(
            meta!,
            video,
            stremioType: parsed.type,
            showId: _splitShowVideoId(parsed.stremioId).showId,
            seasonId: video.season == null
                ? seriesId
                : StremioItemId(parsed.type, '${_splitShowVideoId(parsed.stremioId).showId}:${video.season}').toString(),
          ),
        )
        .toList()
      ..sort(compareEpisodesByWatchOrder);
    for (final episode in episodes) {
      await cache.put(serverId, episode.id, episode.toJson());
    }
    return episodes;
  }

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(String hubId, {int? start, int? size, AbortController? abort}) =>
      _unsupported('fetchMoreHubItemsPage');

  @override
  Future<List<MediaHub>> fetchGlobalHubs({int limit = defaultHubPreviewLimit, bool includePlaybackHubs = true}) async =>
      const [];

  @override
  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist) async => const [];

  @override
  Future<List<MediaItem>> fetchAlbumTracks(String albumId) async => const [];

  @override
  Future<List<MediaItem>> fetchInstantMix(String itemId, {int limit = 100}) => _unsupported('fetchInstantMix');

  @override
  Future<Lyrics?> fetchLyrics(MediaItem track) async => null;

  @override
  Future<List<MediaItem>> searchItems(String query, {int limit = 100, AbortController? abort}) async {
    final catalogs = await _loadCatalogs();
    final results = <MediaItem>[];
    final seen = <String>{};
    for (final catalog in catalogs) {
      if (results.length >= limit) break;
      // Each catalog is searched on its owning addon -- stream addon
      // catalogs only exist there, and asking Cinemeta for them is a 404.
      final addon = catalog.fromStreamAddon ? _streamAddon : _catalogAddon;
      try {
        final extra = <String, String>{};
        if (catalog.supportedExtras.contains('search')) extra['search'] = query;
        final previews = await addon.fetchCatalog(catalog.type, catalog.id, extra: extra.isEmpty ? null : extra);
        for (final preview in previews) {
          final itemId = StremioItemId(preview.type, preview.id).toString();
          if (!seen.add(itemId)) continue;
          results.add(_mapPreviewToItem(preview));
        }
      } on StremioAddonException catch (e) {
        // One unsearchable catalog (addon down, no search support) must not
        // fail the whole search -- other catalogs can still match, and the
        // search screen treats a thrown error as a full-page failure.
        appLogger.d('Stremio: catalog search failed for ${catalog.type}/${catalog.id}: $e');
      }
    }
    return results.take(limit).toList();
  }

  @override
  Future<List<MediaItem>> fetchRecentlyAdded({int limit = 50}) async {
    final catalogs = await _loadCatalogs();
    if (catalogs.isEmpty) return const [];
    final catalog = catalogs.first;
    final addon = catalog.fromStreamAddon ? _streamAddon : _catalogAddon;
    final previews = await addon.fetchCatalog(catalog.type, catalog.id);
    return previews.take(limit).map(_mapPreviewToItem).toList();
  }

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20}) async => const [];

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
  }) async => const [];

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async => const [];

  @override
  Future<List<MediaItem>> fetchExtras(String id) async => const [];

  @override
  Future<List<MediaItem>> fetchPersonMedia(String personId) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(String personId, {int? start, int? size, AbortController? abort}) =>
      _unsupported('fetchPersonMediaPage');

  @override
  Future<void> markWatched(MediaItem item) async {}

  @override
  Future<void> markUnwatched(MediaItem item) async {}

  @override
  Future<void> removeFromContinueWatching(MediaItem item) => _unsupported('removeFromContinueWatching');

  @override
  Future<void> rate(MediaItem item, double rating) => _unsupported('rate');

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) => _unsupported('setFavorite');

  @override
  Future<List<MediaPlaylist>> fetchPlaylists({String playlistType = 'video', bool? smart}) async => const [];

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) async => null;

  @override
  Future<List<MediaItem>> fetchPlaylistItems(String id, {int offset = 0, int limit = 100}) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async =>
      const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) =>
      _unsupported('createPlaylist');

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) =>
      _unsupported('addToPlaylist');

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) => _unsupported('deletePlaylist');

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) => _unsupported('movePlaylistItem');

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) =>
      _unsupported('removeFromPlaylist');

  @override
  Future<List<MediaItem>> fetchCollections(String libraryId) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(String libraryId, {int? start, int? size, AbortController? abort}) =>
      _unsupported('fetchCollectionsPage');

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) => _unsupported('fetchCollectionPage');

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  }) => _unsupported('createCollection');

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) =>
      _unsupported('addToCollection');

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) =>
      _unsupported('removeFromCollection');

  @override
  Future<bool> deleteCollection(MediaItem collection) => _unsupported('deleteCollection');

  @override
  Future<bool> deleteMediaItem(MediaItem item) => _unsupported('deleteMediaItem');

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) async => null;

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) => path ?? '';

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  @override
  Map<String, String> get streamHeaders => const {};

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    final parsed = StremioItemId.parse(itemId);
    // Stremio catalog ids for movies/series are IMDb ids by convention.
    return parsed.stremioId.startsWith('tt') ? ExternalIds(imdb: parsed.stremioId) : const ExternalIds();
  }

  @override
  Future<MediaItem?> findByExternalIds(ExternalIds ids, {required MediaKind kind, String? title, int? year}) async =>
      null;

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(String itemId) async => null;

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({required MediaItem item, required MediaSourceInfo mediaSource}) =>
      Future<ScrubPreviewSource?>.value();

  @override
  double get watchedThreshold => 0.9;

  @override
  bool get marksWatchedOnPlaybackStopped => false;

  @override
  Future<void> reportPlaybackStarted({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) =>
      _unsupported('playback progress reporting');

  @override
  Future<void> reportPlaybackProgress({
    required String itemId,
    required Duration position,
    required Duration duration,
    bool isPaused = false,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) =>
      _unsupported('playback progress reporting');

  @override
  Future<void> reportPlaybackStopped({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? liveStreamId,
    String? mediaSourceId,
    PlaybackReportMetadata report = const PlaybackReportMetadata.live(),
  }) =>
      _unsupported('playback progress reporting');

  /// Resolve [item]'s best stream to a direct playable URL: already-resolved
  /// addon streams are used as-is; torrent-backed streams are added to
  /// Real-Debrid and resolved to a direct link. Picks the first stream that
  /// resolves successfully.
  Future<String?> _resolveDirectUrl(MediaItem item, {int mediaIndex = 0}) async {
    final stremioType = item.raw?['stremioType'] as String?;
    final stremioId = item.raw?['stremioId'] as String?;
    if (stremioType == null || stremioId == null) return null;
    final streams = await _streamAddon.fetchStreams(stremioType, stremioId);
    if (streams.isEmpty) return null;

    // mediaIndex comes from the version picker (populated from these same
    // streams in fetchItem) when the user explicitly chose one -- honor
    // that choice rather than silently falling back to a different stream.
    if (mediaIndex > 0 && mediaIndex < streams.length) {
      final chosen = streams[mediaIndex];
      if (chosen.isDirectUrl) return chosen.url;
      final magnet = chosen.magnetUri;
      if (magnet != null) return _realDebrid.resolveMagnetToDirectLink(magnet);
      return null;
    }

    for (final stream in streams) {
      if (stream.isDirectUrl) return stream.url;
      final magnet = stream.magnetUri;
      if (magnet == null) continue;
      try {
        return await _realDebrid.resolveMagnetToDirectLink(magnet);
      } on RealDebridException catch (e) {
        appLogger.w('Real-Debrid resolution failed for a candidate stream, trying next', error: e);
      }
    }
    return null;
  }

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final videoUrl = await _resolveDirectUrl(options.metadata, mediaIndex: options.selectedMediaIndex);
    if (videoUrl == null) {
      throw const PlaybackException('No resolvable stream found for this item', reason: PlaybackFailureReason.noPlayableSource);
    }
    return PlaybackInitializationResult(availableVersions: const [], videoUrl: videoUrl, isTranscoding: false);
  }

  @override
  LiveTvSupport get liveTv => const NoLiveTvSupport();

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    final videoUrl = await _resolveDirectUrl(item, mediaIndex: mediaIndex);
    return DownloadResolution(videoUrl: videoUrl);
  }

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) {
    final specs = <DownloadArtworkSpec>[];
    if (item.thumbPath != null) specs.add(DownloadArtworkSpec(localKey: item.thumbPath!, url: item.thumbPath!));
    if (item.artPath != null) specs.add(DownloadArtworkSpec(localKey: item.artPath!, url: item.artPath!));
    return specs;
  }

  @override
  Future<String?> resolveExternalPlaybackUrl(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) =>
      _resolveDirectUrl(item, mediaIndex: mediaIndex);
}
