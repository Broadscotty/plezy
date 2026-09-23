import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/src/database.dart';
import 'package:background_downloader/src/models.dart';
import 'package:background_downloader/src/task.dart';

import 'mock_persistent_storage.dart';

final defaultTask = DownloadTask(
  taskId: 'task1',
  url: 'https://google.com',
  group: 'group',
);

late Database db;
late MockPersistentStorage storage;

void main() {
  setUp(() {
    storage = MockPersistentStorage();
    db = Database(storage);
  });

  tearDown(() {
    db.destroy(); // destroys the singleton
  });

  group('Database Listener Test', () {
    test('emits updated record when listener is active', () async {
      final task = defaultTask;
      final record = TaskRecord(task, TaskStatus.running, 0.0, 100);
      final listener = db.updates;
      final completer = Completer<TaskRecord>();
      listener.listen(completer.complete);
      db.updateRecord(record);
      final emittedRecord = await completer.future;
      expect(emittedRecord, equals(record));
    });

    test('emits multiple updated records when listener is active', () async {
      final task1 = defaultTask;
      final task2 = defaultTask.copyWith(taskId: 'task2');
      final record1 = TaskRecord(task1, TaskStatus.running, 0.0, 100);
      final record2 = TaskRecord(task2, TaskStatus.running, 0.0, 100);
      final listener = db.updates;
      var counter = 0;
      listener.listen((record) => counter++);
      await db.updateRecord(record1);
      await db.updateRecord(record2);
      await Future.delayed(const Duration(seconds: 1));
      expect(counter, equals(2));
    });

    test('two listeners receive the same TaskRecord', () async {
      final task = defaultTask;
      final record = TaskRecord(task, TaskStatus.running, 0.0, 100);
      final listener1 = db.updates;
      final listener2 = db.updates;
      final completer1 = Completer<TaskRecord>();
      final completer2 = Completer<TaskRecord>();
      listener1.listen(completer1.complete);
      listener2.listen(completer2.complete);
      await db.updateRecord(record);
      final emittedRecord1 = await completer1.future;
      final emittedRecord2 = await completer2.future;
      expect(emittedRecord1, equals(record));
      expect(emittedRecord2, equals(record));
    });

    test('deleteRecordWithId discards resume temp file and state', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bd_resume_cleanup_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final tempFile = File(
        '${tempDir.path}${Platform.pathSeparator}com.bbflight.background_downloader123',
      );
      await tempFile.writeAsString('partial');
      final task = defaultTask.copyWith(taskId: 'cleanup-task');

      await storage.storeTaskRecord(
        TaskRecord(task, TaskStatus.failed, progressFailed, 100),
      );
      await storage.storePausedTask(task);
      await storage.storeResumeData(ResumeData(task, tempFile.path, 50, 'tag'));

      expect(await tempFile.exists(), isTrue);

      await db.deleteRecordWithId(task.taskId);

      expect(await tempFile.exists(), isFalse);
      expect(await storage.retrieveTaskRecord(task.taskId), isNull);
      expect(await storage.retrievePausedTask(task.taskId), isNull);
      expect(await storage.retrieveResumeData(task.taskId), isNull);
    });

    test('deleteRecordWithId preserves file uri resume data targets', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'bd_resume_uri_cleanup_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final targetFile = File(
        '${tempDir.path}${Platform.pathSeparator}destination-file',
      );
      await targetFile.writeAsString('partial');
      final task = defaultTask.copyWith(taskId: 'cleanup-uri-task');

      await storage.storeTaskRecord(
        TaskRecord(task, TaskStatus.failed, progressFailed, 100),
      );
      await storage
          .storeResumeData(ResumeData(task, targetFile.uri.toString()));

      await db.deleteRecordWithId(task.taskId);

      expect(await targetFile.exists(), isTrue);
      expect(await storage.retrieveResumeData(task.taskId), isNull);
    });

    test('cleanUp by age preserves active records', () async {
      final oldCreationTime = DateTime.now().subtract(
        const Duration(days: 20),
      );
      final runningTask = defaultTask.copyWith(
        taskId: 'old-running-task',
        creationTime: oldCreationTime,
      );
      final waitingTask = defaultTask.copyWith(
        taskId: 'old-waiting-task',
        creationTime: oldCreationTime,
      );
      final failedTask = defaultTask.copyWith(
        taskId: 'old-failed-task',
        creationTime: oldCreationTime,
      );

      await storage.storeTaskRecord(
        TaskRecord(runningTask, TaskStatus.running, 0.0, -1),
      );
      await storage.storeTaskRecord(
        TaskRecord(waitingTask, TaskStatus.waitingToRetry, 0.0, -1),
      );
      await storage.storeTaskRecord(
        TaskRecord(failedTask, TaskStatus.failed, progressFailed, -1),
      );

      db.cleanUp(
        maxAge: const Duration(days: 10),
        maxRecordCount: null,
        autoClean: false,
      );

      await _waitUntil(
        () async => await storage.retrieveTaskRecord(failedTask.taskId) == null,
      );
      expect(await storage.retrieveTaskRecord(runningTask.taskId), isNotNull);
      expect(await storage.retrieveTaskRecord(waitingTask.taskId), isNotNull);
    });

    test('cleanUp by count preserves active records', () async {
      final now = DateTime.now();
      final runningTask = defaultTask.copyWith(
        taskId: 'count-running-task',
        creationTime: now.subtract(const Duration(days: 5)),
      );
      final enqueuedTask = defaultTask.copyWith(
        taskId: 'count-enqueued-task',
        creationTime: now.subtract(const Duration(days: 4)),
      );
      final waitingTask = defaultTask.copyWith(
        taskId: 'count-waiting-task',
        creationTime: now.subtract(const Duration(days: 3)),
      );
      final failedTask = defaultTask.copyWith(
        taskId: 'count-failed-task',
        creationTime: now.subtract(const Duration(days: 2)),
      );
      final completeTask = defaultTask.copyWith(
        taskId: 'count-complete-task',
        creationTime: now.subtract(const Duration(days: 1)),
      );

      await storage.storeTaskRecord(
        TaskRecord(runningTask, TaskStatus.running, 0.0, -1),
      );
      await storage.storeTaskRecord(
        TaskRecord(enqueuedTask, TaskStatus.enqueued, 0.0, -1),
      );
      await storage.storeTaskRecord(
        TaskRecord(waitingTask, TaskStatus.waitingToRetry, 0.0, -1),
      );
      await storage.storeTaskRecord(
        TaskRecord(failedTask, TaskStatus.failed, progressFailed, -1),
      );
      await storage.storeTaskRecord(
        TaskRecord(completeTask, TaskStatus.complete, progressComplete, -1),
      );

      db.cleanUp(maxRecordCount: 2, maxAge: null, autoClean: false);

      await _waitUntil(() async {
        return await storage.retrieveTaskRecord(failedTask.taskId) == null &&
            await storage.retrieveTaskRecord(completeTask.taskId) == null;
      });
      expect(await storage.retrieveTaskRecord(runningTask.taskId), isNotNull);
      expect(await storage.retrieveTaskRecord(enqueuedTask.taskId), isNotNull);
      expect(await storage.retrieveTaskRecord(waitingTask.taskId), isNotNull);
      expect(await storage.retrieveAllTaskRecords(), hasLength(3));
    });
  });
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for condition');
}

