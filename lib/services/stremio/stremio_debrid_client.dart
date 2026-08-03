import '../../exceptions/media_server_exceptions.dart';
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

  /// Stremio catalog descriptors this addon exposes, read from its manifest
  /// (`type`, `id`, `name`). Populated lazily on first [fetchLibraries] call.
  List<({String type, String id, String name})>? _catalogs;

  bool _offlineMode = false;

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
  }) : _streamAddon = StremioAddonClient(addonUrl: addonUrl),
       _catalogAddon = StremioAddonClient(addonUrl: _cinemetaUrl),
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

  Future<List<({String type, String id, String name})>> _loadCatalogs() async {
    final cached = _catalogs;
    if (cached != null) return cached;
    final manifest = await _catalogAddon.fetchManifest();
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
        // Only "top" is generically browsable with just skip/pagination.
        // Cinemeta's other catalogs either require parameters only Stremio's
        // own app supplies internally (New/year needs a required genre;
        // Last videos/Calendar videos need specific show-id lists for
        // episode-release tracking, not general browsing) or would multiply
        // into several near-duplicate library entries per type.
        .where((c) => c.id == 'top')
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
      raw: {'stremioType': preview.type, 'stremioId': preview.id, 'addonUrl': _streamAddon.addonUrl},
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
          title: catalog.type == 'series' ? 'TV Shows' : 'Movies',
          kind: catalog.type == 'series' ? MediaKind.show : MediaKind.movie,
          serverId: serverId.toString(),
          serverName: 'Stremio',
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
    try {
      final previews = await _catalogAddon.fetchCatalog(parts[0], parts[1], extra: {'skip': skip.toString()});
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

  /// Fetch a show's full meta, tolerant of season/episode-suffixed ids: strips
  /// the suffix so Cinemeta's /meta endpoint (show-level only) resolves.
  Future<StremioMetaPreview?> _fetchShowMeta(String type, String stremioId) async {
    final showId = _splitShowVideoId(stremioId).showId;
    return _catalogAddon.fetchMeta(type, showId);
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
        title: meta.name,
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
        title: meta?.name,
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
    for (final catalog in catalogs) {
      if (results.length >= limit) break;
      final previews = await _catalogAddon.fetchCatalog(catalog.type, catalog.id, extra: {'search': query});
      results.addAll(previews.map(_mapPreviewToItem));
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
