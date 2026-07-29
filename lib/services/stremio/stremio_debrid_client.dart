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
import '../../media/media_sort.dart';
import '../../media/media_source_info.dart';
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

/// [MediaServerClient] backed by a single Stremio addon, resolving streams
/// through Real-Debrid rather than a live media server.
class StremioDebridClient extends MediaServerClient {
  @override
  final ServerId serverId;
  @override
  final String? serverName;

  final StremioAddonClient _addon;
  final RealDebridClient _realDebrid;

  /// Stremio catalog descriptors this addon exposes, read from its manifest
  /// (`type`, `id`, `name`). Populated lazily on first [fetchLibraries] call.
  List<({String type, String id, String name})>? _catalogs;

  bool _offlineMode = false;

  StremioDebridClient({
    required this.serverId,
    required String addonUrl,
    required String realDebridApiToken,
    this.serverName,
  }) : _addon = StremioAddonClient(addonUrl: addonUrl),
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
    _addon.close();
    _realDebrid.close();
  }

  @override
  Future<HealthStatus> checkHealth() async {
    try {
      await _addon.fetchManifest();
      return HealthStatus.online;
    } on StremioAddonException catch (e) {
      appLogger.w('Stremio addon health check failed', error: e);
      return HealthStatus.offline;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async => serverId.toString();

  Future<List<({String type, String id, String name})>> _loadCatalogs() async {
    final cached = _catalogs;
    if (cached != null) return cached;
    final manifest = await _addon.fetchManifest();
    final rawCatalogs = manifest['catalogs'] as List? ?? const [];
    final catalogs = rawCatalogs
        .whereType<Map<String, dynamic>>()
        .map(
          (c) => (
            type: c['type'] as String? ?? 'movie',
            id: c['id'] as String? ?? '',
            name: c['name'] as String? ?? (c['id'] as String? ?? 'Catalog'),
          ),
        )
        .where((c) => c.id.isNotEmpty)
        .toList();
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
      raw: {'stremioType': preview.type, 'stremioId': preview.id, 'addonUrl': _addon.addonUrl},
    );
  }

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    final catalogs = await _loadCatalogs();
    return [
      for (final catalog in catalogs)
        MediaLibrary(
          id: '${catalog.type}|${catalog.id}',
          backend: MediaBackend.debrid,
          title: catalog.name,
          kind: catalog.type == 'series' ? MediaKind.show : MediaKind.movie,
        ),
    ];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryContent(String libraryId, LibraryQuery query) =>
      fetchLibraryPagedContent(libraryId, query: query);

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
    final previews = await _addon.fetchCatalog(parts[0], parts[1], extra: {'skip': skip.toString()});
    final items = previews.map(_mapPreviewToItem).toList();
    return LibraryPage(items: items, totalCount: fallbackPageTotal(offset: skip, itemCount: items.length), offset: skip);
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
    final parsed = StremioItemId.parse(id);
    final meta = await _addon.fetchMeta(parsed.type, parsed.stremioId);
    if (meta == null) return null;
    return _mapPreviewToItem(meta);
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(String id) async =>
      (item: await fetchItem(id), onDeckEpisode: null);

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async => const [];

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

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(String parentId, {int? start, int? size, AbortController? abort}) =>
      _unsupported('fetchChildrenPage');

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) => _unsupported('fetchPlayableDescendantsPage');

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async => const [];

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
      final previews = await _addon.fetchCatalog(catalog.type, catalog.id, extra: {'search': query});
      results.addAll(previews.map(_mapPreviewToItem));
    }
    return results.take(limit).toList();
  }

  @override
  Future<List<MediaItem>> fetchRecentlyAdded({int limit = 50}) async {
    final catalogs = await _loadCatalogs();
    if (catalogs.isEmpty) return const [];
    final previews = await _addon.fetchCatalog(catalogs.first.type, catalogs.first.id);
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

  /// Resolve [item]'s best stream to a direct playable URL: already-resolved
  /// addon streams are used as-is; torrent-backed streams are added to
  /// Real-Debrid and resolved to a direct link. Picks the first stream that
  /// resolves successfully.
  Future<String?> _resolveDirectUrl(MediaItem item) async {
    final stremioType = item.raw?['stremioType'] as String?;
    final stremioId = item.raw?['stremioId'] as String?;
    if (stremioType == null || stremioId == null) return null;
    final streams = await _addon.fetchStreams(stremioType, stremioId);
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
    final videoUrl = await _resolveDirectUrl(options.metadata);
    if (videoUrl == null) {
      throw const PlaybackException('No resolvable stream found for this item', reason: PlaybackFailureReason.noPlayableSource);
    }
    return PlaybackInitializationResult(availableVersions: const [], videoUrl: videoUrl, isTranscoding: false);
  }

  @override
  LiveTvSupport get liveTv => const NoLiveTvSupport();

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    final videoUrl = await _resolveDirectUrl(item);
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
      _resolveDirectUrl(item);
}
