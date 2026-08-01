import '../../exceptions/media_server_exceptions.dart';
import '../../media/download_resolution.dart';
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
import '../../media/media_version.dart';
import '../../media/media_sort.dart';
import '../../media/media_source_info.dart';
import '../../media/playback_report_metadata.dart';
import '../../media/server_capabilities.dart';
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import '../../utils/formatters.dart';
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
  final http.Client _http;

  /// Full catalog descriptors from the Cinemeta manifest, including
  /// `extraRequired` so we skip catalogs that need user-provided params
  /// (e.g. `movie/year` requires a year-genre). Populated lazily on first
  /// [fetchLibraries] call.
  List<({String type, String id, String name, List<String> extraRequired})>? _catalogs;

  bool _offlineMode = false;

  /// Stremio's official Cinemeta metadata addon for catalog browsing.
  /// Torrentio addons provide streams only; Cinemeta provides catalogs
  /// and metadata, same as real Stremio where Cinemeta populates Discover.
  static const _cinemetaUrl = 'https://v3-cinemeta.strem.io';


  StremioDebridClient({
    required this.serverId,
    required String addonUrl,
    required String realDebridApiToken,
    this.serverName,
  }) : _streamAddon = StremioAddonClient(addonUrl: addonUrl),
       _catalogAddon = StremioAddonClient(addonUrl: _cinemetaUrl),
       _realDebrid = RealDebridClient(apiToken: realDebridApiToken),
       _http = http.Client();

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
    _http.close();
  }

  @override
  Future<HealthStatus> checkHealth() async {
    try {
      // Check the addon the user actually configured (the stream provider) --
      // that's the one whose validity matters to them, since the catalog
      // addon (Cinemeta) is fixed and always assumed reachable. The manifest
      // is cached in StremioAddonClient (15 min TTL) so this is cheap after
      // the first fetch; Torrentio can take ~20s cold.
      await _streamAddon.fetchManifest();
      return HealthStatus.online;
    } catch (e) {
      // Catch everything including TimeoutException — a slow addon must not
      // take down the whole bind/rebind flow or remove a configured server.
      appLogger.w('Stremio addon health check failed: $e');
      return HealthStatus.offline;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async => serverId.toString();

  Future<List<({String type, String id, String name, List<String> extraRequired})>> _loadCatalogs() async {
    final cached = _catalogs;
    if (cached != null) return cached;
    // Try manifest first (for future-proofing), fall back to hardcoded.
    try {
      final manifest = await _catalogAddon.fetchManifest();
      final rawCatalogs = manifest['catalogs'] as List? ?? const [];
      final catalogs = rawCatalogs
          .whereType<Map<String, dynamic>>()
          .map((c) => (
            type: c['type'] as String? ?? 'movie',
            id: c['id'] as String? ?? '',
            name: c['name'] as String? ?? (c['id'] as String? ?? 'Catalog'),
            extraRequired: (c['extraRequired'] as List?)?.cast<String>() ?? const <String>[],
          ))
          .where((c) => c.id.isNotEmpty)
          .where((c) => c.extraRequired.isEmpty)
          .toList();
      _catalogs = catalogs;
      appLogger.i('Stremio: loaded ${catalogs.length} catalogs from manifest');
      return catalogs;
    } catch (e) {
      appLogger.w('Stremio: manifest fetch failed, using hardcoded catalogs', error: e);
      _catalogs = const [
        (type: 'movie', id: 'top', name: 'Popular Movies', extraRequired: <String>[]),
        (type: 'series', id: 'top', name: 'Popular Series', extraRequired: <String>[]),
        (type: 'movie', id: 'imdbRating', name: 'Featured Movies', extraRequired: <String>[]),
        (type: 'series', id: 'imdbRating', name: 'Featured Series', extraRequired: <String>[]),
      ];
      return _catalogs!;
    }
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

  /// Minimal item used when Cinemeta meta is unreachable (flaky mobile DNS).
  /// Streams still load from the stream addon, so playback/download resolution
  /// keep working; the title is best-effort and degrades to the item id.
  MediaItem _fallbackItemFromId(StremioItemId parsed) {
    final kind = parsed.type == 'series' ? MediaKind.show : MediaKind.movie;
    return MediaItem(
      id: StremioItemId(parsed.type, parsed.stremioId).toString(),
      backend: MediaBackend.debrid,
      kind: kind,
      title: parsed.stremioId,
      serverId: serverId.toString(),
      serverName: serverName,
      raw: {'stremioType': parsed.type, 'stremioId': parsed.stremioId, 'addonUrl': _streamAddon.addonUrl},
    );
  }

  /// Best-effort title from a stream name like "The Prestige (2006) 1080p
  /// WEB-DL x264": strip leading decorations, cut at the first bracket marker,
  /// keep through the parenthesized year. Returns null when the name is too
  /// messy to trust, so the caller falls back to the item id.
  String? _titleFromStreamName(String? name) {
    if (name == null) return null;
    var s = name.replaceAll(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '').trim();
    if (s.isEmpty) return null;
    final bracket = s.indexOf('[');
    if (bracket > 0) s = s.substring(0, bracket).trim();
    if (s.isEmpty) return null;
    final yearMatch = RegExp(r'^(.*?\(\d{4}\))').firstMatch(s);
    if (yearMatch != null) {
      s = yearMatch.group(1)!.trim();
    } else if (s.length > 80) {
      s = s.substring(0, 80);
    }
    // Reject names that are just quality/size markers with no real title.
    if (!s.contains(RegExp(r'\p{L}', unicode: true))) return null;
    return s;
  }

  /// Two flat libraries: Movies and TV Shows, each backed by Cinemeta catalogs
  /// through the persistent addon client. No folders — Plezy's browse grid
  /// shows content directly like a real Plex server.
  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    try {
      await _loadCatalogs(); // ensure catalogs are populated
    } on StremioAddonException catch (e) {
      appLogger.w('Stremio: Cinemeta catalog load failed, falling back to empty list', error: e);
      _catalogs = const [];
    }
    return [
      MediaLibrary(
        id: 'stremio_movies',
        backend: MediaBackend.debrid,
        title: 'Stremio Movies',
        kind: MediaKind.movie,
        serverId: serverId.toString(),
        serverName: serverName,
      ),
      MediaLibrary(
        id: 'stremio_tv',
        backend: MediaBackend.debrid,
        title: 'Stremio TV Shows',
        kind: MediaKind.show,
        serverId: serverId.toString(),
        serverName: serverName,
      ),
    ];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryContent(String libraryId, LibraryQuery query) {
    return fetchLibraryPagedContent(libraryId, query: query);
  }

  /// Flat paged content: routes to the right catalog set by library id.
  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    if (libraryId == 'stremio_movies') {
      return _fetchCatalogContent('movie', offset: query.offset, limit: query.limit);
    }
    if (libraryId == 'stremio_tv') {
      return _fetchCatalogContent('series', offset: query.offset, limit: query.limit);
    }
    throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Unknown debrid library: $libraryId');
  }

  /// Fetch + merge both catalogs (top + imdbRating) for [type], then
  /// paginate client-side. Cinemeta catalogs don't support server-side
  /// pagination natively so we fetch the full set and slice here.
  Future<LibraryPage<MediaItem>> _fetchCatalogContent(
    String type, {
    int offset = 0,
    int limit = 50,
  }) async {
    final seen = <String>{};
    final merged = <MediaItem>[];
    for (final catalog in const ['top', 'imdbRating']) {
      try {
        final previews = await _catalogAddon.fetchCatalog(type, catalog);
        for (final preview in previews) {
          if (seen.add(preview.id)) {
            merged.add(_mapPreviewToItem(preview));
          }
        }
      } on StremioAddonException catch (e) {
        appLogger.w('Stremio: catalog $type/$catalog failed, continuing', error: e);
      }
    }
    final total = merged.length;
    final page = merged.skip(offset).take(limit).toList();
    return LibraryPage(items: page, totalCount: total, offset: offset);
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

  @override
  Future<MediaItem?> fetchItem(String id) async {
    try {
      final parsed = StremioItemId.parse(id);
      // Season ids are "series:SHOW:season:N". Cinemeta only knows the show
      // id; build the season item from the show's meta so the season detail
      // page (and its episode pager) resolve.
      if (parsed.type == 'series' && parsed.stremioId.contains(':season:')) {
        final showId = parsed.stremioId.split(':season:').first;
        final seasonNumber = int.tryParse(parsed.stremioId.split(':season:').last) ?? 0;
        final showMeta = await _catalogAddon.fetchMeta(parsed.type, showId);
        if (showMeta == null) return null;
        return MediaItem(
          id: StremioItemId(parsed.type, parsed.stremioId).toString(),
          backend: MediaBackend.debrid,
          kind: MediaKind.season,
          title: 'Season $seasonNumber',
          index: seasonNumber,
          parentId: showMeta.id,
          parentTitle: showMeta.name,
          serverId: serverId.toString(),
          serverName: serverName,
          raw: {'stremioType': parsed.type, 'stremioId': parsed.stremioId, 'addonUrl': _streamAddon.addonUrl},
        );
      }

      // v3-cinemeta's DNS is flaky on some mobile networks (intermittent
      // "Failed host lookup" for v3-cinemeta.strem.io while cinemeta-catalogs
      // resolves fine). A meta failure must NOT fail the item: streams are
      // fetched independently below and are all that playback/download
      // resolution actually needs. Fall back to a minimal item; a later
      // offline-pin backfills the real metadata when the resolver recovers.
      StremioMetaPreview? meta;
      try {
        meta = await _catalogAddon.fetchMeta(parsed.type, parsed.stremioId);
      } catch (e) {
        appLogger.w('Stremio: meta fetch failed for ${parsed.stremioId}, using fallback item: $e');
      }
      final item = meta != null ? _mapPreviewToItem(meta) : _fallbackItemFromId(parsed);
      // Populate mediaVersions from the stream addon so Plezy's existing
      // version pickers (playback sheet + download version dialog) surface
      // the full stream list for this item. Best effort: stream fetch
      // failures degrade to the version-less item rather than failing.
      List<StremioStream> streams;
      try {
        streams = await _fetchFilteredStreams(item);
      } catch (e) {
        appLogger.w('Stremio: stream fetch failed for ${parsed.stremioId}, returning item without versions: $e');
        return item;
      }
      if (streams.isNotEmpty) {
        final versions = <MediaVersion>[
          for (var i = 0; i < streams.length; i++) _mediaVersionForStream(streams[i], i),
        ];
        var result = item.copyWith(mediaVersions: versions);
        if (meta == null) {
          final fallbackTitle = _titleFromStreamName(streams.first.title ?? streams.first.name);
          if (fallbackTitle != null && fallbackTitle.isNotEmpty) {
            result = result.copyWith(title: fallbackTitle);
          }
        }
        return result;
      }
      return item;
    } on ArgumentError {
      return null;
    }
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(String id) async =>
      (item: await fetchItem(id), onDeckEpisode: null);

  @override
  /// Return a show's seasons when [parentId] is a show, or a season's
  /// episodes when it's a season. Cinemeta's meta response carries all videos
  /// flat; the show path groups them into season items (Plex/Jellyfin shape)
  /// so the detail screen's season selector works, and the season path
  /// filters to that season's episodes.
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    try {
      final parsed = StremioItemId.parse(parentId);
      // Season ids are "series:SHOW:season:N"; Cinemeta only knows the bare show
      // id. Strip the suffix before asking Cinemeta, then filter its flat video
      // list to the requested season below.
      final showId = parsed.stremioId.contains(':season:')
          ? parsed.stremioId.split(':season:').first
          : parsed.stremioId;
      final meta = await _catalogAddon.fetchMeta(parsed.type, showId);
      final videos = meta?.videos;
      if (videos == null || videos.isEmpty) return const [];

      final isShow = parsed.type == 'series' && videos.any((v) => v.season != null && v.season! > 0);
      if (!isShow) {
        // Movie or a series meta without structured videos: no seasons.
        return const [];
      }

      if (parsed.type == 'series' && parsed.stremioId.contains(':season:')) {
        // Season id form "series:SHOW:season:N" — return that season's episodes.
        final seasonNumber = int.tryParse(parsed.stremioId.split(':season:').last) ?? 0;
        return videos
            .where((v) => v.season == seasonNumber)
            .map((video) => _episodeItem(video, parentId: parsed.stremioId, showId: parsed.stremioId, meta: meta))
            .toList();
      }

      // Show id — group videos into season items.
      final seasonNumbers = <int>{};
      for (final v in videos) {
        final s = v.season;
        if (s != null && s > 0) seasonNumbers.add(s);
      }
      final sorted = seasonNumbers.toList()..sort();
      return [
        for (final s in sorted)
          MediaItem(
            id: StremioItemId(parsed.type, '${parsed.stremioId}:season:$s').toString(),
            backend: MediaBackend.debrid,
            kind: MediaKind.season,
            title: 'Season $s',
            index: s,
            parentId: parsed.stremioId,
            parentTitle: meta?.name,
            serverId: serverId.toString(),
            serverName: serverName,
            raw: {'stremioType': parsed.type, 'stremioId': parsed.stremioId, 'addonUrl': _streamAddon.addonUrl},
          ),
      ];
    } on ArgumentError {
      return const [];
    }
  }

  MediaItem _episodeItem(
    StremioMetaVideo video, {
    required String parentId,
    required String showId,
    required StremioMetaPreview? meta,
  }) {
    return MediaItem(
      id: StremioItemId('series', video.id).toString(),
      backend: MediaBackend.debrid,
      kind: MediaKind.episode,
      title: video.title,
      summary: video.overview,
      index: video.episode,
      parentIndex: video.season,
      parentId: parentId,
      parentTitle: meta?.name,
      thumbPath: video.thumbnail,
      serverId: serverId.toString(),
      serverName: serverName,
      raw: {'stremioType': 'series', 'stremioId': video.id, 'addonUrl': _streamAddon.addonUrl},
    );
  }

  @override
  Future<List<MediaItem>> fetchLibraryFolders(String libraryId, {void Function(List<MediaItem> itemsSoFar)? onPage}) async =>
      const [];

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(String parentId, {int? start, int? size, AbortController? abort}) async {
    // Season detail pages page through episodes via this call; the base
    // [fetchChildren] already returns that season's episodes. Cinemeta
    // returns everything at once, so honor start/size as a simple slice.
    final children = await fetchChildren(parentId);
    final startIndex = start ?? 0;
    final endIndex = size == null ? children.length : (startIndex + size).clamp(0, children.length);
    if (startIndex >= children.length) return LibraryPage(items: const [], totalCount: children.length, offset: startIndex);
    return LibraryPage(
      items: children.sublist(startIndex, endIndex),
      totalCount: children.length,
      offset: startIndex,
    );
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) => _unsupported('fetchPlayableDescendantsPage');

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) => fetchChildren(parentId);

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async => null;

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
    for (final catalog in catalogs) {
      if (results.length >= limit) break;
      try {
        final previews = await _catalogAddon.fetchCatalog(catalog.type, catalog.id, extra: {'search': query});
        results.addAll(previews.map(_mapPreviewToItem));
      } on StremioAddonException catch (e) {
        appLogger.w('Stremio: search $query on ${catalog.type}/${catalog.id} failed', error: e);
      }
    }
    return results.take(limit).toList();
  }

  @override
  Future<List<MediaItem>> fetchRecentlyAdded({int limit = 50}) async {
    final catalogs = await _loadCatalogs();
    if (catalogs.isEmpty) return const [];
    final previews = await _catalogAddon.fetchCatalog(catalogs.first.type, catalogs.first.id);
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
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(String libraryId, {int? start, int? size, AbortController? abort}) async =>
      const LibraryPage(items: [], totalCount: 0);

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
  }) async {}

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
  }) async {}

  @override
  Future<void> reportPlaybackStopped({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? liveStreamId,
    String? mediaSourceId,
    PlaybackReportMetadata report = const PlaybackReportMetadata.live(),
  }) async {}


  /// Fetch all candidate streams for [item], dropping 4K (phone playback) and
  /// sorting best-first (1080p, then 720p, then the rest).
  Future<List<StremioStream>> _fetchFilteredStreams(MediaItem item) async {
    final stremioType = item.raw?['stremioType'] as String?;
    final stremioId = item.raw?['stremioId'] as String?;
    if (stremioType == null || stremioId == null) {
      appLogger.w('Stremio: cannot resolve stream - missing type/id');
      return const [];
    }
    List<StremioStream> rawStreams;
    try {
      rawStreams = await _streamAddon.fetchStreams(stremioType, stremioId);
    } on StremioAddonException catch (e) {
      appLogger.e('Stremio: stream addon fetch failed', error: e);
      return const [];
    }
    if (rawStreams.isEmpty) {
      appLogger.w('Stremio: stream addon returned zero streams');
      return const [];
    }
    appLogger.i('Stremio: got ${rawStreams.length} streams. First: url=${rawStreams.first.url != null}, infoHash=${rawStreams.first.infoHash != null}, title=${rawStreams.first.title}');
    // Sort streams: prefer 1080p, then 720p. Skip 4K (phone playback).
    int score(StremioStream s) {
      final t = (s.title ?? s.name ?? '').toLowerCase();
      if (t.contains('2160p') || t.contains('4k')) return -1;
      if (t.contains('1080p')) return 100;
      if (t.contains('720p')) return 80;
      return 50;
    }
    final streams = rawStreams.where((s) => score(s) >= 0).toList()
      ..sort((a, b) => score(b).compareTo(score(a)));
    appLogger.i('Stremio: ${rawStreams.length} raw streams, ${streams.length} within 1080p cap');
    return streams;
  }

  /// Extract the resolution label from a Torrentio-style stream title.
  String? _resolutionFromTitle(StremioStream stream) {
    final t = (stream.title ?? stream.name ?? '').toLowerCase();
    if (t.contains('2160p') || t.contains('4k')) return '2160';
    if (t.contains('1080p')) return '1080';
    if (t.contains('720p')) return '720';
    if (t.contains('480p')) return '480';
    return null;
  }

  /// Human-readable file size for a stream: prefer the addon-reported
  /// `behaviorHints.videoSize`, then a "2.5GB"-style token in the title.
  String? _sizeLabel(StremioStream stream) {
    if (stream.sizeBytes != null && stream.sizeBytes! > 0) {
      return ByteFormatter.formatBytes(stream.sizeBytes!);
    }
    final title = (stream.title ?? '').toLowerCase();
    final match = RegExp(r'([\d.]+)\s*(gb|gib)').firstMatch(title);
    if (match != null) return '${match.group(1)}GB';
    return null;
  }

  /// Build the picker entry for one stream. The stream title carries the
  /// readable quality ("Meteor 1080p", "Torrentio RD • 1080p • WEB-DL"), so
  /// it becomes the version name. Size is appended when known so the picker
  /// shows what the user is actually selecting ("Meteor 1080p · 10.1 GB");
  /// [displayLabel] falls back to the name when no parsed tech fields exist.
  MediaVersion _mediaVersionForStream(StremioStream stream, int index) {
    final resolution = _resolutionFromTitle(stream);
    final base = stream.title ?? stream.name ?? 'Stream ${index + 1}';
    final size = _sizeLabel(stream);
    final name = (size != null && !base.toLowerCase().contains(size.toLowerCase()))
        ? '$base · $size'
        : base;
    return MediaVersion(
      id: '$index',
      name: name,
      videoResolution: resolution,
      height: resolution != null ? int.tryParse(resolution) : null,
    );
  }

  /// Resolve a single [stream] to a playable URL. Already-resolved addon
  /// streams (Torrentio + RD direct links) play as-is; torrent-backed streams
  /// are added to Real-Debrid and resolved to a direct link.
  Future<String?> _resolveStreamUrl(StremioStream stream) async {
    if (stream.isDirectUrl) {
      appLogger.i('Stremio: playing direct url ${stream.url}');
      return stream.url;
    }
    final magnet = stream.magnetUri;
    if (magnet == null) {
      appLogger.w('Stremio: stream has neither direct url nor infoHash');
      return null;
    }
    try {
      appLogger.i('Stremio: resolving magnet via RD...');
      final direct = await _realDebrid.resolveMagnetToDirectLink(magnet);
      appLogger.i('Stremio: RD resolved -> $direct');
      return direct;
    } on RealDebridException catch (e) {
      appLogger.w('Stremio: RD resolution failed: ${e.message}', error: e);
      return null;
    }
  }

  /// Resolve the stream at [index]. When [strict] (an explicit user pick)
  /// only that stream is tried; otherwise a failed resolve falls through the
  /// remaining best-first list (e.g. an uncached magnet) like the legacy
  /// auto-pick behavior.
  Future<String?> _resolveStreamAt(List<StremioStream> streams, int index, {required bool strict}) async {
    if (index < 0 || index >= streams.length) index = 0;
    final picked = await _resolveStreamUrl(streams[index]);
    if (picked != null || strict) return picked;
    for (var i = 0; i < streams.length; i++) {
      if (i == index) continue;
      final url = await _resolveStreamUrl(streams[i]);
      if (url != null) return url;
    }
    return null;
  }

  /// Resolve [item]'s stream at [mediaIndex] (defaults to best) to a direct
  /// playable URL: already-resolved addon streams are used as-is;
  /// torrent-backed streams are added to Real-Debrid and resolved to a direct
  /// link.
  Future<String?> _resolveDirectUrl(MediaItem item, {int? mediaIndex}) async {
    // Stream list fetch can hit transient DNS/connection failures on mobile
    // networks. Retry once before giving up.
    List<StremioStream>? streams;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        streams = await _fetchFilteredStreams(item);
        break;
      } catch (e) {
        appLogger.w('Stremio: stream fetch attempt ${attempt + 1}/2 failed: $e');
        if (attempt == 0) await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (streams == null || streams.isEmpty) return null;
    final index = (mediaIndex ?? 0).clamp(0, streams.length - 1);
    return _resolveStreamAt(streams, index, strict: mediaIndex != null);
  }

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final streams = await _fetchFilteredStreams(options.metadata);
    if (streams.isEmpty) {
      throw PlaybackException(
        'No playable stream found. Check Stremio addon and Real-Debrid token.',
        reason: PlaybackFailureReason.noPlayableSource,
      );
    }
    // Expose every candidate stream as a version so the player's existing
    // quality/version sheet doubles as the stream picker.
    final versions = <MediaVersion>[
      for (var i = 0; i < streams.length; i++) _mediaVersionForStream(streams[i], i),
    ];
    final selectedIndex = options.selectedMediaIndex >= 0 && options.selectedMediaIndex < streams.length
        ? options.selectedMediaIndex
        : 0;
    // An explicit user pick (reload after a version-sheet selection) must
    // resolve exactly the picked stream; the initial auto-pick may fall
    // through to the next candidate if the best one fails to resolve.
    final explicit = options.selectedMediaSourceId != null;
    final videoUrl = await _resolveStreamAt(streams, selectedIndex, strict: explicit);
    if (videoUrl == null) {
      throw PlaybackException(
        'No playable stream found. Check Stremio addon and Real-Debrid token.',
        reason: PlaybackFailureReason.noPlayableSource,
      );
    }
    return PlaybackInitializationResult(
      availableVersions: versions,
      videoUrl: videoUrl,
      isTranscoding: false,
      selectedMediaIndex: selectedIndex,
    );
  }

  @override
  LiveTvSupport get liveTv => const NoLiveTvSupport();

  /// Follow an AIOStreams-style /playback/... proxy link through its redirect
  /// chain to the final Real-Debrid direct download link
  /// (https://...download.real-debrid.com/d/...). RD direct links are stable,
  /// full-speed and resumable; the proxy URL is a signed session token that
  /// expires mid-download. Best-effort: returns the original URL when the chain
  /// can't be resolved.
  Future<String> resolveToDirectDownloadLink(String url) async {
    try {
      var current = Uri.parse(url);
      for (var i = 0; i < 6; i++) {
        final request = http.Request('GET', current)..followRedirects = false;
        final response = await _http.send(request).timeout(const Duration(seconds: 30));
        final status = response.statusCode;
        if (status >= 300 && status < 400) {
          final location = response.headers['location'];
          await response.stream.drain();
          if (location == null) return url;
          current = current.resolve(location);
          continue;
        }
        if (status >= 200 && status < 300) {
          // Cancel the body transfer immediately (we only need the URL).
          final sub = response.stream.listen((_) {});
          await sub.cancel();
          if (current.host.contains('real-debrid')) return current.toString();
          return current.toString() == Uri.parse(url).toString() ? url : current.toString();
        }
        await response.stream.drain();
        return url;
      }
      return url;
    } catch (e) {
      appLogger.w('Stremio: failed to resolve direct download link for $url: $e');
      return url;
    }
  }

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    var videoUrl = await _resolveDirectUrl(item, mediaIndex: mediaIndex);
    if (videoUrl != null) {
    // Follow AIOStreams' /playback/ proxy chain to the final Real-Debrid /d/
    // link: stable, full RD speed, resumable. The proxy token expires mid-
    // download. Falls back to the original URL if the chain can't be resolved.
    final direct = await resolveToDirectDownloadLink(videoUrl);
    if (direct != videoUrl) {
      appLogger.i('Stremio: resolved download to RD direct link (${Uri.parse(direct).host})');
      videoUrl = direct;
    } else {
      // Not a proxy chain - try RD unrestrict as before.
      try {
        final unrestricted = await _realDebrid.unrestrictLink(videoUrl);
        appLogger.i('Stremio: download unrestricted to RD direct link');
        videoUrl = unrestricted;
      } catch (e) {
        appLogger.w('Stremio: unrestrict failed, using original download URL: $e');
      }
    }
  }
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
