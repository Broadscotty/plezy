import 'package:flutter/foundation.dart';
import '../mixins/disposable_change_notifier_mixin.dart';
import '../services/storage_service.dart';

/// Provider for managing hidden library state across the app.
/// This ensures that when a library is hidden/unhidden in one screen,
/// all other screens are automatically updated.
class HiddenLibrariesProvider extends ChangeNotifier with DisposableChangeNotifierMixin {
  StorageService? _storageService;
  final String? profileId;
  Set<String> _hiddenLibraryKeys = {};
  Set<String> _deletedLibraryKeys = {};
  bool _isInitialized = false;
  Future<void>? _initFuture;

  HiddenLibrariesProvider({this._storageService, this.profileId}) {
    // Start initialization eagerly to reduce race conditions
    _initFuture = _initialize();
  }

  /// Ensures the provider is initialized. Call this before accessing hidden
  /// libraries in contexts where you need the actual persisted values.
  Future<void> ensureInitialized() => _initFuture ?? _initialize();

  /// Check if the provider has completed initialization
  bool get isInitialized => _isInitialized;

  /// Get an unmodifiable copy of hidden library keys
  Set<String> get hiddenLibraryKeys => Set.unmodifiable(_hiddenLibraryKeys);

  /// Get an unmodifiable copy of deleted library keys
  Set<String> get deletedLibraryKeys => Set.unmodifiable(_deletedLibraryKeys);

  /// Library keys that should never appear in any surface (hidden ∪ deleted).
  Set<String> get excludedKeys => _hiddenLibraryKeys.union(_deletedLibraryKeys);

  /// Initialize the provider by loading hidden libraries from storage
  Future<void> _initialize() async {
    if (_isInitialized) return;
    await _loadFromStorage();
    _isInitialized = true;
    safeNotifyListeners();
  }

  Future<void> _loadFromStorage() async {
    final storage = _storageService ??= await StorageService.getInstance();
    final scopedProfileId = profileId;
    _hiddenLibraryKeys = scopedProfileId == null
        ? storage.getHiddenLibraries()
        : storage.getHiddenLibrariesForProfile(scopedProfileId);
    _deletedLibraryKeys = scopedProfileId == null
        ? storage.getDeletedLibraries()
        : storage.getDeletedLibrariesForProfile(scopedProfileId);
  }

  Future<void> _saveToStorage() async {
    final storage = _storageService ??= await StorageService.getInstance();
    final scopedProfileId = profileId;
    if (scopedProfileId == null) {
      await storage.saveHiddenLibraries(_hiddenLibraryKeys);
    } else {
      await storage.saveHiddenLibrariesForProfile(scopedProfileId, _hiddenLibraryKeys);
    }
  }

  Future<void> _saveDeletedToStorage() async {
    final storage = _storageService ??= await StorageService.getInstance();
    final scopedProfileId = profileId;
    if (scopedProfileId == null) {
      await storage.saveDeletedLibraries(_deletedLibraryKeys);
    } else {
      await storage.saveDeletedLibrariesForProfile(scopedProfileId, _deletedLibraryKeys);
    }
  }

  /// Hide a library by its key
  /// Updates both in-memory state and persistent storage
  Future<void> hideLibrary(String libraryKey) async {
    if (!_isInitialized) await _initialize();
    if (!_hiddenLibraryKeys.contains(libraryKey)) {
      _hiddenLibraryKeys = Set.from(_hiddenLibraryKeys)..add(libraryKey);
      await _saveToStorage();
      safeNotifyListeners();
    }
  }

  /// Unhide a library by its key
  /// Updates both in-memory state and persistent storage
  Future<void> unhideLibrary(String libraryKey) async {
    if (!_isInitialized) await _initialize();
    if (_hiddenLibraryKeys.contains(libraryKey)) {
      _hiddenLibraryKeys = Set.from(_hiddenLibraryKeys)..remove(libraryKey);
      await _saveToStorage();
      safeNotifyListeners();
    }
  }

  /// Check if a specific library is hidden
  bool isLibraryHidden(String libraryKey) => _hiddenLibraryKeys.contains(libraryKey);

  /// Check if a specific library is deleted (tombstoned)
  bool isLibraryDeleted(String libraryKey) => _deletedLibraryKeys.contains(libraryKey);

  /// Permanently delete a library. Unlike hiding, the library will not appear
  /// in any surface until the connection is removed and re-added (which
  /// generates a new serverId / globalKey). The library's per-library
  /// preferences are scrubbed at the call site, not here.
  Future<void> deleteLibrary(String libraryKey) async {
    if (!_isInitialized) await _initialize();
    if (!_deletedLibraryKeys.contains(libraryKey)) {
      _deletedLibraryKeys = Set.from(_deletedLibraryKeys)..add(libraryKey);
      await _saveDeletedToStorage();
      safeNotifyListeners();
    }
  }

  /// Refresh hidden libraries from storage
  /// Useful if storage was modified outside the provider
  Future<void> refresh() async {
    await _loadFromStorage();
    _isInitialized = true;
    safeNotifyListeners();
  }
}
