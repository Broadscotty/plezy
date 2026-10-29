import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

void main() {
  group('reconcileStalledDownloads', () {
    test('re-queues a downloading row that no native task owns', () async {
      final fixture = await _createFixture();
      await _seedDownloading(fixture, bgTaskId: 'vanished-task');
      final manager = _manager(fixture);
      addTearDown(manager.dispose);

      final requeued = await manager.reconcileStalledDownloads(nativeTasks: const []);

      expect(requeued, 1);
      final row = await fixture.db.getDownloadedMedia(fixture.metadata.globalKey);
      expect(row?.status, DownloadStatus.queued.index);
      expect(row?.bgTaskId, isNull);
      expect(await fixture.db.getNextQueueItem(), isNotNull);
    });

    test('leaves a download alone while its native task still exists', () async {
      final fixture = await _createFixture();
      await _seedDownloading(fixture, bgTaskId: 'live-task');
      final manager = _manager(fixture);
      addTearDown(manager.dispose);

      final requeued = await manager.reconcileStalledDownloads(
        nativeTasks: [_task('live-task', fixture.metadata.globalKey)],
      );

      expect(requeued, 0);
      final row = await fixture.db.getDownloadedMedia(fixture.metadata.globalKey);
      expect(row?.status, DownloadStatus.downloading.index);
      expect(row?.bgTaskId, 'live-task');
    });

    test('completes a stranded row whose video is already on disk', () async {
      final fixture = await _createFixture();
      await _seedDownloading(fixture, bgTaskId: 'vanished-task');
      await fixture.db.updateVideoFilePath(fixture.metadata.globalKey, 'downloads/srv/item-1/video.mp4');
      final manager = _manager(fixture);
      addTearDown(manager.dispose);

      final requeued = await manager.reconcileStalledDownloads(nativeTasks: const []);

      expect(requeued, 0);
      final row = await fixture.db.getDownloadedMedia(fixture.metadata.globalKey);
      expect(row?.status, DownloadStatus.completed.index);
      expect(row?.videoFilePath, 'downloads/srv/item-1/video.mp4');
    });

    test('ignores rows that are already finished or queued', () async {
      final fixture = await _createFixture();
      await fixture.db.insertDownload(
        serverId: ServerId('srv'),
        ratingKey: fixture.metadata.id,
        globalKey: fixture.metadata.globalKey,
        type: 'movie',
        status: DownloadStatus.queued.index,
      );
      await fixture.db.addToQueue(mediaGlobalKey: fixture.metadata.globalKey);
      final manager = _manager(fixture);
      addTearDown(manager.dispose);

      expect(await manager.reconcileStalledDownloads(nativeTasks: const []), 0);
      expect((await fixture.db.getDownloadedMedia(fixture.metadata.globalKey))?.status, DownloadStatus.queued.index);
    });
  });
}

DownloadManagerService _manager(_Fixture fixture) {
  return DownloadManagerService(
    database: fixture.db,
    storageService: fixture.storage,
    clientResolver: (serverId, {clientScopeId}) => null,
    downloadsSupportedOverride: true,
  );
}

DownloadTask _task(String taskId, String globalKey) {
  return DownloadTask(
    taskId: taskId,
    url: 'https://example.test/video.mp4',
    filename: 'video.mp4',
    directory: 'downloads',
    metaData: globalKey,
  );
}

Future<void> _seedDownloading(_Fixture fixture, {required String bgTaskId}) async {
  await fixture.db.insertDownload(
    serverId: ServerId('srv'),
    ratingKey: fixture.metadata.id,
    globalKey: fixture.metadata.globalKey,
    type: 'movie',
    status: DownloadStatus.downloading.index,
  );
  await fixture.db.updateBgTaskId(fixture.metadata.globalKey, bgTaskId);
  await fixture.db.addToQueue(mediaGlobalKey: fixture.metadata.globalKey);
}

Future<_Fixture> _createFixture() async {
  resetSharedPreferencesForTest();
  SettingsService.resetForTesting();
  DownloadStorageService.resetForTesting();
  final tempDir = await Directory.systemTemp.createTemp('download_reconcile_test_');
  final previousPathProvider = PathProviderPlatform.instance;
  PathProviderPlatform.instance = FakePathProvider(tempDir);
  final storage = DownloadStorageService.instance;
  await storage.initialize(await SettingsService.getInstance());
  final fixture = _Fixture(
    tempDir: tempDir,
    previousPathProvider: previousPathProvider,
    db: AppDatabase.forTesting(NativeDatabase(File(p.join(tempDir.path, 'downloads.sqlite')))),
    storage: storage,
    metadata: testMediaItem(
      id: 'item-1',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      serverId: ServerId('srv'),
      title: 'Movie',
    ),
  );
  PlexApiCache.initialize(fixture.db);
  JellyfinApiCache.initialize(fixture.db);
  addTearDown(fixture.dispose);
  return fixture;
}

class _Fixture {
  _Fixture({
    required this.tempDir,
    required this.previousPathProvider,
    required this.db,
    required this.storage,
    required this.metadata,
  });

  final Directory tempDir;
  final PathProviderPlatform previousPathProvider;
  final AppDatabase db;
  final DownloadStorageService storage;
  final MediaItem metadata;

  Future<void> dispose() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }
}
