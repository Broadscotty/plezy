import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_persistent_storage.dart';

/// Tests for [BaseDownloader] lifecycle logic, using the desktop downloader
/// with in-memory storage. No test performs an actual download.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  final storage = MockPersistentStorage();
  final downloader = FileDownloader(
    persistentStorage: storage,
  ).downloaderForTesting;

  late Directory tempDir;

  setUp(() async {
    await FileDownloader().ready;
    await downloader.resetUpdatesStreamController();
    tempDir = await Directory.systemTemp.createTemp('bd_base_downloader_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  DownloadTask taskInTempDir(String taskId) => DownloadTask(
        taskId: taskId,
        url: 'https://example.com/$taskId',
        filename: '$taskId.bin',
        directory: tempDir.path,
        baseDirectory: BaseDirectory.root,
        updates: Updates.statusAndProgress,
      );

  group('terminal progress invariant', () {
    test('exactly one terminal progress, emitted before the final status',
        () async {
      // The desktop isolate and the native platforms no longer emit terminal
      // progress; processStatusUpdate synthesizes it. This guards against
      // drift across the three implementations: a platform that re-adds its
      // own terminal progress would double this count in integration tests,
      // and the Dart synthesis asserted here must never be removed.
      final task = taskInTempDir('finalization-task');
      final events = <TaskUpdate>[];
      final subscription = FileDownloader().updates.listen(events.add);
      addTearDown(subscription.cancel);

      downloader.processStatusUpdate(
        TaskStatusUpdate(task, TaskStatus.complete),
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final progressUpdates = events.whereType<TaskProgressUpdate>().toList();
      final statusUpdates = events.whereType<TaskStatusUpdate>().toList();
      expect(progressUpdates, hasLength(1));
      expect(progressUpdates.single.progress, progressComplete);
      expect(statusUpdates, hasLength(1));
      expect(statusUpdates.single.status, TaskStatus.complete);
      expect(
        events.indexOf(progressUpdates.single),
        lessThan(events.indexOf(statusUpdates.single)),
      );
    });
  });

  group('setResumeData stale data guard', () {
    test('discards resume data and temp file for final-state task', () async {
      final task = taskInTempDir('stale-final-task');
      final partFile = File('${tempDir.path}/stale-final.part');
      await partFile.writeAsString('partial');
      await storage.storeTaskRecord(
        TaskRecord(task, TaskStatus.complete, progressComplete, 100),
      );

      await downloader.setResumeData(ResumeData(task, partFile.path, 50, 'e'));

      expect(await storage.retrieveResumeData(task.taskId), isNull);
      expect(await partFile.exists(), isFalse);
    });

    test('preserves resume data for task waiting to retry', () async {
      final task = taskInTempDir('stale-retry-task');
      final partFile = File('${tempDir.path}/stale-retry.part');
      await partFile.writeAsString('partial');
      // native platforms post resumeData before the failed status that
      // schedules the retry, so the record may already be in a final state
      await storage.storeTaskRecord(
        TaskRecord(task, TaskStatus.failed, progressFailed, 100),
      );
      downloader.tasksWaitingToRetry.add(task);
      addTearDown(() => downloader.tasksWaitingToRetry.remove(task));

      await downloader.setResumeData(ResumeData(task, partFile.path, 50, 'e'));

      expect(await storage.retrieveResumeData(task.taskId), isNotNull);
      expect(await partFile.exists(), isTrue);
    });
  });

  group('resume data sweep', () {
    test('sweeps resume data arriving just after a final status', () async {
      // untracked task (no database record), so the setResumeData guard
      // cannot catch the late arrival - only the sweep can
      final task = taskInTempDir('sweep-task');
      final partFile = File('${tempDir.path}/sweep.part');
      await partFile.writeAsString('partial');

      downloader.processStatusUpdate(
        TaskStatusUpdate(task, TaskStatus.canceled),
      );
      await Future.delayed(const Duration(milliseconds: 200));
      await downloader.setResumeData(ResumeData(task, partFile.path, 50, 'e'));
      expect(await storage.retrieveResumeData(task.taskId), isNotNull);

      await Future.delayed(const Duration(milliseconds: 1200));
      expect(await storage.retrieveResumeData(task.taskId), isNull);
      expect(await partFile.exists(), isFalse);
    });

    test('re-enqueue invalidates the pending sweep', () async {
      final task = taskInTempDir('sweep-invalidated-task');
      final partFile = File('${tempDir.path}/sweep-invalidated.part');
      await partFile.writeAsString('partial');

      downloader.processStatusUpdate(
        TaskStatusUpdate(task, TaskStatus.canceled),
      );
      await Future.delayed(const Duration(milliseconds: 200));
      // prepareEnqueueAll performs enqueue bookkeeping (including sweep
      // invalidation) without starting platform work
      // ignore: invalid_use_of_protected_member
      await downloader.prepareEnqueueAll([task]);
      await downloader.setResumeData(ResumeData(task, partFile.path, 50, 'e'));

      await Future.delayed(const Duration(milliseconds: 1200));
      expect(await storage.retrieveResumeData(task.taskId), isNotNull);
      expect(await partFile.exists(), isTrue);
      await downloader.discardResumeData(task.taskId);
    });
  });

  group('resume data replacement on enqueue', () {
    test('discards other task resume data targeting the same destination',
        () async {
      final existingTask = taskInTempDir('replaced-task');
      final newTask = existingTask.copyWith(taskId: 'replacing-task');
      final partFile = File('${tempDir.path}/replaced.part');
      await partFile.writeAsString('partial');
      await storage.storeResumeData(
        ResumeData(existingTask, partFile.path, 50, 'e'),
      );

      // ignore: invalid_use_of_protected_member
      await downloader.prepareEnqueueAll([newTask]);

      expect(await storage.retrieveResumeData(existingTask.taskId), isNull);
      expect(await partFile.exists(), isFalse);
    });

    test('keeps resume data when the enqueued task itself resumes', () async {
      final task = taskInTempDir('self-resuming-task');
      final partFile = File('${tempDir.path}/self-resuming.part');
      await partFile.writeAsString('partial');
      await storage.storeResumeData(ResumeData(task, partFile.path, 50, 'e'));

      // ignore: invalid_use_of_protected_member
      await downloader.prepareEnqueueAll([task]);

      expect(await storage.retrieveResumeData(task.taskId), isNotNull);
      expect(await partFile.exists(), isTrue);
      await downloader.discardResumeData(task.taskId);
    });
  });

  group('desktop cancel before isolate start', () {
    test('emits exactly one canceled status', () async {
      final task = taskInTempDir('cancel-before-start-task');
      final events = <TaskUpdate>[];
      final canceledReceived = Completer<void>();
      final subscription = FileDownloader().updates.listen((update) {
        events.add(update);
        if (update is TaskStatusUpdate &&
            update.status == TaskStatus.canceled &&
            !canceledReceived.isCompleted) {
          canceledReceived.complete();
        }
      });
      addTearDown(subscription.cancel);

      expect(await downloader.enqueue(task), isTrue);
      // cancel immediately: the isolate has not completed its handshake, so
      // this exercises the cancel-before-sendPort (initiallyCanceled) path
      await downloader.cancelPlatformTasksWithIds([task.taskId]);
      await canceledReceived.future.timeout(const Duration(seconds: 10));
      // allow any (unexpected) trailing updates to arrive
      await Future.delayed(const Duration(milliseconds: 500));

      final statusUpdates = events
          .whereType<TaskStatusUpdate>()
          .where((update) => update.task.taskId == task.taskId)
          .toList();
      expect(
        statusUpdates.map((update) => update.status),
        [TaskStatus.enqueued, TaskStatus.canceled],
      );
      final terminalProgress = events
          .whereType<TaskProgressUpdate>()
          .where((update) => update.progress == progressCanceled)
          .toList();
      expect(terminalProgress, hasLength(1));
    });
  });
}
