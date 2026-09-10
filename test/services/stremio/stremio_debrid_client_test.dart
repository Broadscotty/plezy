import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/stremio/stremio_debrid_client.dart';

// ---------------------------------------------------------------------------
// Stub responses
// ---------------------------------------------------------------------------

/// Minimal Formulio manifest: one series catalog, meta serves `hpy...` ids.
const _formulioManifest = <String, dynamic>{
  'id': 'org.stremio.formulio',
  'name': 'Formulio',
  'resources': [
    'catalog',
    <String, dynamic>{'name': 'meta', 'types': ['series'], 'idPrefixes': ['hpy']},
    <String, dynamic>{'name': 'stream', 'types': ['series'], 'idPrefixes': ['hpy']},
  ],
  'catalogs': [
    <String, dynamic>{
      'type': 'series',
      'id': 'formulio-series',
      'name': 'Formulio',
      'extra': [
        <String, dynamic>{'isRequired': false, 'name': 'search'},
        <String, dynamic>{'isRequired': false, 'name': 'genre', 'options': ['Formula Racing', 'Moto Racing']},
      ],
    },
  ],
};

/// Minimal Cinemeta manifest: two `top` catalogs (movie + series), both
/// named "Popular" -- plus `year` catalogs that must NOT appear in the
/// browsable list.
const _cinemetaManifest = <String, dynamic>{
  'id': 'com.linvo.cinemeta',
  'name': 'Cinemeta',
  'resources': ['catalog', 'meta', 'addon_catalog'],
  'catalogs': [
    <String, dynamic>{'type': 'movie', 'id': 'top', 'name': 'Popular'},
    <String, dynamic>{'type': 'series', 'id': 'top', 'name': 'Popular'},
    <String, dynamic>{'type': 'movie', 'id': 'year', 'name': 'New'},
  ],
};

/// A Formulio meta response with two seasons of episodes.
const _formulioMeta = <String, dynamic>{
  'meta': {
    'id': 'hpytt0202601',
    'type': 'series',
    'name': 'Sky F1',
    'releaseInfo': '2026',
    'poster': 'https://img.example.com/sf1.jpg',
    'videos': [
      <String, dynamic>{'id': 'hpytt0202601:11:1', 'season': 11, 'episode': 1, 'title': 'FP1 - Hungary GP'},
      <String, dynamic>{'id': 'hpytt0202601:11:2', 'season': 11, 'episode': 2, 'title': 'FP2 - Hungary GP'},
      <String, dynamic>{'id': 'hpytt0202601:12:1', 'season': 12, 'episode': 1, 'title': 'FP1 - Dutch GP'},
    ],
  },
};

/// A Cinemeta meta response for tt1234567 (movie).
const _cinemetaMeta = <String, dynamic>{
  'meta': {
    'id': 'tt1234567',
    'type': 'movie',
    'name': 'Test Movie',
    'releaseInfo': '2024',
    'poster': 'https://img.example.com/poster.jpg',
  },
};

/// Formulio catalog rows.
const _formulioCatalog = <String, dynamic>{
  'metas': [
    <String, dynamic>{'id': 'hpytt0202601', 'type': 'series', 'name': 'Sky F1'},
    <String, dynamic>{'id': 'hpytt0202611', 'type': 'series', 'name': 'MotoGP'},
  ],
};

/// Formulio catalog search results.
const _formulioSearchResults = <String, dynamic>{
  'metas': [
    <String, dynamic>{'id': 'hpytt0202601', 'type': 'series', 'name': 'Sky F1 (search match)'},
  ],
};

/// Formulio streams response.
const _formulioStreams = <String, dynamic>{
  'streams': [
    <String, dynamic>{'url': 'https://direct.example.com/stream.mp4'},
  ],
};

// ---------------------------------------------------------------------------
// Mock HTTP client
// ---------------------------------------------------------------------------

/// Routes Stremio-protocol requests by host to the right stub.
class _MockStremioClient extends http.Client {
  final Map<String, dynamic> streamManifest;
  final Map<String, dynamic> cinemetaManifest;
  final Map<String, dynamic>? streamMeta;
  final Map<String, List<Map<String, dynamic>>>? streamStreams;
  final Map<String, dynamic>? streamSearch;
  final Map<String, dynamic>? cinemetaMeta;
  final Map<String, dynamic>? cinemetaSearch;
  final bool cinemetaDown;

  _MockStremioClient({
    required this.streamManifest,
    required this.cinemetaManifest,
    this.streamMeta,
    this.streamStreams,
    this.streamSearch,
    this.cinemetaMeta,
    this.cinemetaSearch,
    this.cinemetaDown = false,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    final host = uri.host;
    final path = uri.path;
    final hasSearchParam = uri.queryParameters.containsKey('search');

    // --- Stream addon routes (Formulio / custom addon) ---
    if (host.contains('formulio') || host.contains('test')) {
      if (path.endsWith('/manifest.json')) return _respond(streamManifest);
      if (path.startsWith('/catalog/')) {
        if (streamSearch != null && hasSearchParam) return _respond(streamSearch);
        return _respond(_formulioCatalog);
      }
      if (path.startsWith('/meta/')) return _respond(streamMeta ?? _formulioMeta);
      if (path.startsWith('/stream/')) return _respond(streamStreams ?? _formulioStreams);
    }

    // --- Cinemeta routes ---
    if (host.contains('cinemeta')) {
      if (path.endsWith('/manifest.json')) return _respond(cinemetaManifest);
      if (cinemetaDown) return _respond(<String, dynamic>{}, status: 503);
      if (path.startsWith('/catalog/')) {
        if (cinemetaSearch != null && hasSearchParam) return _respond(cinemetaSearch);
        return _respond(const <String, dynamic>{'metas': <dynamic>[]});
      }
      if (path.startsWith('/meta/')) return _respond(cinemetaMeta ?? const <String, dynamic>{});
    }

    return _respond(const <String, dynamic>{}, status: 404);
  }

  http.StreamedResponse _respond(dynamic body, {int status = 200}) {
    final jsonStr = body is String ? body : jsonEncode(body);
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonStr)),
      status,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  void close() {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

StremioDebridClient _buildClient({
  String addonUrl = 'https://formulio.test',
  Map<String, dynamic>? streamManifest,
  Map<String, dynamic>? cinemetaManifest,
  Map<String, dynamic>? streamMeta,
  Map<String, dynamic>? streamSearch,
  Map<String, dynamic>? cinemetaMeta,
  bool cinemetaDown = false,
}) {
  return StremioDebridClient(
    serverId: '1',
    addonUrl: addonUrl,
    realDebridApiToken: 'test-token',
    serverName: 'Test Debrid',
    httpClient: _MockStremioClient(
      streamManifest: streamManifest ?? _formulioManifest,
      cinemetaManifest: cinemetaManifest ?? _cinemetaManifest,
      streamMeta: streamMeta,
      streamSearch: streamSearch,
      cinemetaMeta: cinemetaMeta,
      cinemetaDown: cinemetaDown,
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  group('_loadCatalogs / fetchLibraries', () {
    test('merges stream addon catalogs with Cinemeta top catalogs', () async {
      final client = _buildClient();
      final libs = await client.fetchLibraries();
      expect(libs, hasLength(3)); // Formulio + Cinemeta movie top + series top
    });

    test('stream addon catalogs come first', () async {
      final client = _buildClient();
      final libs = await client.fetchLibraries();
      expect(libs[0].id, 'series|formulio-series');
      expect(libs[1].id, 'movie|top');
      expect(libs[2].id, 'series|top');
    });

    test('stream addon library title uses manifest name', () async {
      final client = _buildClient();
      final libs = await client.fetchLibraries();
      expect(libs[0].title, 'Formulio');
    });

    test('Cinemeta fallback libraries use generic titles not "Popular"', () async {
      final client = _buildClient();
      final libs = await client.fetchLibraries();
      expect(libs[1].title, 'Movies');
      expect(libs[2].title, 'TV Shows');
    });

    test('stream addon library serverName is the manifest name', () async {
      final client = _buildClient();
      final libs = await client.fetchLibraries();
      expect(libs[0].serverName, 'Formulio');
    });

    test('Cinemeta library serverName is "Stremio"', () async {
      final client = _buildClient();
      final libs = await client.fetchLibraries();
      expect(libs[1].serverName, 'Stremio');
      expect(libs[2].serverName, 'Stremio');
    });

    test('all libraries have debrid backend', () async {
      final client = _buildClient();
      final libs = await client.fetchLibraries();
      for (final lib in libs) {
        expect(lib.backend, MediaBackend.debrid);
      }
    });

    test('stream addon series library kind is show', () async {
      final client = _buildClient();
      final libs = await client.fetchLibraries();
      expect(libs[0].kind, MediaKind.show);
    });

    test('falls back to Cinemeta-only when stream addon manifest fails', () async {
      final client = _buildClient(streamManifest: const {});
      final libs = await client.fetchLibraries();
      expect(libs, hasLength(2));
      expect(libs[0].id, 'movie|top');
      expect(libs[1].id, 'series|top');
    });
  });

  group('fetchLibraryPagedContent', () {
    test('fetches Formulio catalog via stream addon without skip extra', () async {
      final client = _buildClient();
      final page = await client.fetchLibraryPagedContent(
        'series|formulio-series',
        query: const LibraryQuery(offset: 0),
      );
      expect(page.items, hasLength(2));
      expect(page.items[0].title, 'Sky F1');
      expect(page.items[0].id, 'series|hpytt0202601');
    });

    test('unknown library id falls back to Cinemeta addon', () async {
      final client = _buildClient();
      final page = await client.fetchLibraryPagedContent(
        'movie|top',
        query: const LibraryQuery(offset: 0),
      );
      // Cinemeta top catalog stub returns empty metas by default.
      expect(page.items, isEmpty);
    });
  });

  group('fetchItem (meta routing)', () {
    test('routes hpy... id to stream addon for meta', () async {
      final client = _buildClient();
      final item = await client.fetchItem('series|hpytt0202601');
      expect(item, isNotNull);
      expect(item!.title, 'Sky F1');
      expect(item.year, 2026);
    });

    test('hpy... items get seasons from Formulio meta', () async {
      final client = _buildClient();
      final seasons = await client.fetchChildren('series|hpytt0202601');
      // Formulio meta has seasons 11 and 12 → 2 season rows.
      expect(seasons, hasLength(2));
    });

    test('routes tt... id to Cinemeta for meta', () async {
      final client = _buildClient();
      final item = await client.fetchItem('movie|tt1234567');
      expect(item, isNotNull);
      expect(item!.title, 'Test Movie');
      expect(item.year, 2024);
    });
  });

  group('searchItems', () {
    test('searches each catalog via its owning addon', () async {
      final mockClient = _MockStremioClient(
        streamManifest: _formulioManifest,
        cinemetaManifest: _cinemetaManifest,
        streamSearch: _formulioSearchResults,
      );
      final client = StremioDebridClient(
        serverId: '1',
        addonUrl: 'https://formulio.test',
        realDebridApiToken: 'test-token',
        serverName: 'Test',
        httpClient: mockClient,
      );
      final results = await client.searchItems('test');
      // Formulio search returns 1 result; Cinemeta top returns empty.
      expect(results, hasLength(1));
      expect(results[0].title, 'Sky F1 (search match)');
    });

    test('doesn't throw when Cinemeta is down', () async {
      final mockClient = _MockStremioClient(
        streamManifest: _formulioManifest,
        cinemetaManifest: _cinemetaManifest,
        cinemetaDown: true,
      );
      final client = StremioDebridClient(
        serverId: '1',
        addonUrl: 'https://formulio.test',
        realDebridApiToken: 'test-token',
        serverName: 'Test',
        httpClient: mockClient,
      );
      // Should not throw; Formulio search still works.
      final results = await client.searchItems('test');
      expect(results, isNotEmpty);
    });
  });

  group('fetchRecentlyAdded', () {
    test('uses the first catalog and its owning addon', () async {
      final client = _buildClient();
      final items = await client.fetchRecentlyAdded(limit: 10);
      // First catalog is Formulio; its catalog endpoint returns 2 items.
      expect(items, hasLength(2));
    });
  });
}
