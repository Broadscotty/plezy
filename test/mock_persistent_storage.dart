import 'package:background_downloader/src/database.dart';
import 'package:background_downloader/src/models.dart';
import 'package:background_downloader/src/persistent_storage.dart';
import 'package:background_downloader/src/task.dart';

/// In-memory [PersistentStorage] for unit tests.
class MockPersistentStorage implements PersistentStorage {
  final _taskRecords = <String, TaskRecord>{};
  final _pausedTasks = <String, Task>{};
  final _resumeData = <String, ResumeData>{};

  @override
  Future<void> storeTaskRecord(TaskRecord record) async {
    _taskRecords[record.taskId] = record;
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) {
    return Future.value(_taskRecords[taskId]);
  }

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() {
    return Future.value(_taskRecords.values.toList());
  }

  @override
  Future<void> removeTaskRecord(String? taskId) async {
    if (taskId == null) {
      _taskRecords.clear();
    } else {
      _taskRecords.remove(taskId);
    }
  }

  @override
  (String, int) get currentDatabaseVersion => ('mock', 1);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> removePausedTask(String? taskId) async {
    if (taskId == null) {
      _pausedTasks.clear();
    } else {
      _pausedTasks.remove(taskId);
    }
  }

  @override
  Future<void> removeResumeData(String? taskId) async {
    if (taskId == null) {
      _resumeData.clear();
    } else {
      _resumeData.remove(taskId);
    }
  }

  @override
  Future<List<Task>> retrieveAllPausedTasks() {
    return Future.value(_pausedTasks.values.toList());
  }

  @override
  Future<List<ResumeData>> retrieveAllResumeData() {
    return Future.value(_resumeData.values.toList());
  }

  @override
  Future<Task?> retrievePausedTask(String taskId) {
    return Future.value(_pausedTasks[taskId]);
  }

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) {
    return Future.value(_resumeData[taskId]);
  }

  @override
  Future<void> storePausedTask(Task task) async {
    _pausedTasks[task.taskId] = task;
  }

  @override
  Future<void> storeResumeData(ResumeData resumeData) async {
    _resumeData[resumeData.taskId] = resumeData;
  }

  @override
  Future<(String, int)> get storedDatabaseVersion =>
      Future.value(currentDatabaseVersion);
}
