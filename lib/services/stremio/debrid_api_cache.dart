import 'dart:convert';

import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../media/ids.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../api_cache.dart';

/// [ApiCache] for the debrid backend. Unlike Plex/Jellyfin, debrid items
/// carry no live-server connection to resolve at read time -- everything
/// needed to reconstruct a [MediaItem] (poster/background URLs, addon
/// source, resolved link) is already absolute and self-contained in the
/// cached JSON, so this is a straight decode with no absolutizer step.
class DebridApiCache extends ApiCache {
  static final _singleton = ApiCacheSingleton<DebridApiCache>(MediaBackend.debrid, 'DebridApiCache');
  static DebridApiCache get instance => _singleton.instance;

  DebridApiCache._(super.db);

  static void initialize(AppDatabase db) => _singleton.install(DebridApiCache._(db));

  @override
  Future<void> deleteForItem(ServerId serverId, String itemId) async {
    await (database.delete(database.apiCache)..where((t) => t.cacheKey.equals('$serverId:$itemId'))).go();
  }

  @override
  Future<void> pinForOffline(ServerId serverId, String itemId) async {
    await (database.update(database.apiCache)..where((t) => t.cacheKey.equals('$serverId:$itemId'))).write(
      const ApiCacheCompanion(pinned: Value(true)),
    );
  }

  @override
  Future<MediaItem?> getMetadata(ServerId serverId, String itemId) async {
    final row = await (database.select(
      database.apiCache,
    )..where((t) => t.cacheKey.equals('$serverId:$itemId'))).getSingleOrNull();
    if (row == null) return null;
    try {
      return MediaItem.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> applyWatchState({
    required ServerId serverId,
    required String itemId,
    required bool isWatched,
    int? viewOffsetMs,
    int? lastViewedAt,
    int? viewedLeafCount,
  }) async {
    // Debrid has no server-side watch state to sync -- this backend's watch
    // state lives entirely in Plezy's own local database (same mechanism
    // as offline-played items on the other backends), not in this cache.
  }

  @override
  Future<Map<String, MediaItem>> getAllPinnedMetadata({Set<ServerId>? cacheServerIds}) async {
    final query = database.select(database.apiCache)..where((t) => t.pinned.equals(true));
    final rows = await query.get();
    final result = <String, MediaItem>{};
    for (final row in rows) {
      final parts = row.cacheKey.split(':');
      if (parts.length < 2) continue;
      final rowServerId = ServerId(parts.first);
      if (cacheServerIds != null && !cacheServerIds.contains(rowServerId)) continue;
      try {
        final item = MediaItem.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
        result[item.globalKey] = item;
      } catch (_) {
        // Skip malformed rows.
      }
    }
    return result;
  }
}
