import 'dart:async';

import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import '../credential_vault.dart';
import '../settings_service.dart';
import '../trackers/tracker_id_resolver.dart';
import 'stremio_api_client.dart';

/// Real-time watch-progress sync to a connected Stremio account (Route B:
/// writes straight into the Stremio cloud datastore, so Continue Watching
/// and resume behave exactly like the official clients).
///
/// Mirrors the lifecycle shape of `TraktScrobbleService` and is invoked from
/// the same call sites in `video_player_screen.dart` / `playback_services.dart`.
/// Every failure is logged and swallowed — sync must never disturb playback.
class StremioSyncService {
  /// Minimum gap between in-playback progress pushes.
  static const Duration _pushThrottle = Duration(seconds: 30);

  /// Playback fraction that flips the item to watched.
  static const double _watchedThreshold = 0.85;

  static StremioSyncService? _instance;
  static StremioSyncService get instance => _instance ??= StremioSyncService._();

  StremioSyncService._();

  bool _initialized = false;
  bool _enabled = false;
  String? _protectedAuthKey;
  StremioApiClient? _api;

  int _revision = 0;
  _StremioTarget? _target;
  int _positionMs = 0;
  int? _durationMs;
  DateTime? _lastPushAt;
  bool _pushing = false;

  // ---------------------------------------------------------------- status
  // On-screen diagnostics. There is no adb on Scott's phone, so the settings
  // screen is the only place a sync failure can ever be seen.

  DateTime? _lastAttemptAt;
  DateTime? _lastSuccessAt;
  String? _lastError;
  String? _lastTargetLabel;
  String? _lastSkipReason;
  int _successCount = 0;

  DateTime? get lastAttemptAt => _lastAttemptAt;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  String? get lastError => _lastError;
  String? get lastTargetLabel => _lastTargetLabel;
  String? get lastSkipReason => _lastSkipReason;
  int get successCount => _successCount;

  /// Re-reads the enable pref and auth key on next use. Called by the
  /// settings screen after connect, disconnect, or toggle changes.
  void invalidateCachedAuth() {
    _initialized = false;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    final settings = await SettingsService.getInstance();
    _enabled = settings.read(SettingsService.enableStremioSync);
    _protectedAuthKey = settings.read(SettingsService.stremioAuthKey);
  }

  bool get _canSync => _enabled && _protectedAuthKey != null;

  Future<String?> _revealAuthKey() async {
    await _ensureInitialized();
    final protected = _protectedAuthKey;
    if (protected == null) return null;
    try {
      return await CredentialVault.reveal(protected);
    } catch (e) {
      appLogger.d('Stremio: could not reveal auth key', error: e);
      return null;
    }
  }

  void _clear() {
    _target = null;
    _positionMs = 0;
    _durationMs = null;
    _lastPushAt = null;
  }

  /// Drop the current session without pushing. Kept for symmetry with the
  /// Trakt service (profile switches, disable-mid-playback).
  void cancelInFlight() {
    ++_revision;
    _clear();
  }

  void _noteSkip(String reason) {
    _lastSkipReason = reason;
    appLogger.d('Stremio: skipping sync — $reason');
  }

  Future<void> startPlayback(MediaItem metadata, MediaServerClient client, {bool isLive = false}) async {
    final revision = ++_revision;
    _clear();
    await _ensureInitialized();
    if (!_canSync) {
      _noteSkip(!_enabled ? 'sync toggle is off' : 'not connected');
      return;
    }
    if (isLive) {
      _noteSkip('live stream');
      return;
    }
    if (revision != _revision) return;

    final isEpisode = metadata.kind == MediaKind.episode;
    if (metadata.kind != MediaKind.movie && !isEpisode) {
      _noteSkip('not a movie or episode (${metadata.kind.name})');
      return;
    }

    final resolver = TrackerIdResolver(client, needsFribb: () => false);
    String? imdb;
    _StremioTarget? target;

    if (isEpisode) {
      final season = metadata.parentIndex;
      final number = metadata.index;
      if (season == null || number == null) {
        _noteSkip('no season/episode for ${metadata.id}');
        return;
      }
      final showIds = await resolver.resolveShowForEpisode(metadata, includeAnimeProgress: false);
      if (revision != _revision) return;
      imdb = showIds?.external.imdb;
      if (imdb == null) {
        _noteSkip('no show IMDb id for ${metadata.id}');
        return;
      }
      target = _StremioTarget(
        imdb: imdb,
        isEpisode: true,
        season: season,
        episode: number,
        title: metadata.grandparentTitle ?? metadata.parentTitle ?? metadata.title ?? '',
      );
    } else {
      final ids = await resolver.resolveForMovie(metadata.id);
      if (revision != _revision) return;
      imdb = ids?.external.imdb;
      if (imdb == null) {
        _noteSkip('no movie IMDb id for ${metadata.id}');
        return;
      }
      target = _StremioTarget(imdb: imdb, isEpisode: false, title: metadata.title ?? '');
    }

    _target = target;
    _positionMs = metadata.viewOffsetMs ?? 0;
    _durationMs = metadata.durationMs;
    _lastPushAt = null;
    _lastSkipReason = null;
    _lastTargetLabel = target.isEpisode
        ? '${target.title} S${target.season}E${target.episode}'
        : target.title;
    // Seed Continue Watching right away (throttled pushes keep it fresh).
    unawaited(_push());
  }

  void updatePosition(Duration position) {
    if (_target == null) return;
    _positionMs = position.inMilliseconds;
    final last = _lastPushAt;
    if (last != null && DateTime.now().difference(last) < _pushThrottle) return;
    unawaited(_push());
  }

  void updateDuration(Duration duration) {
    if (_target == null) return;
    _durationMs = duration.inMilliseconds;
  }

  Future<void> pausePlayback() async {
    if (_target == null) return;
    await _push(force: true);
  }

  Future<void> resumePlayback() async {
    // No push needed on resume; the next position update covers it.
  }

  Future<void> stopPlayback() async {
    final revision = ++_revision;
    if (_target == null) {
      _clear();
      return;
    }
    await _push(force: true);
    if (revision == _revision) _clear();
  }

  Future<void> _push({bool force = false}) async {
    if (_pushing) return;
    final target = _target;
    if (target == null) return;

    final now = DateTime.now();
    final lastPushAt = _lastPushAt;
    if (!force && lastPushAt != null && now.difference(lastPushAt) < _pushThrottle) return;

    final durationMs = _durationMs;
    if (durationMs == null || durationMs <= 0) {
      _noteSkip('no duration reported by the player yet');
      return;
    }

    _pushing = true;
    _lastAttemptAt = DateTime.now();
    final revision = _revision;
    try {
      final authKey = await _revealAuthKey();
      if (authKey == null) {
        _lastError = 'stored auth key could not be decrypted';
        return;
      }
      final positionMs = _positionMs.clamp(0, durationMs).toInt();
      final markWatched = positionMs / durationMs >= _watchedThreshold;
      final iso = now.toUtc().toIso8601String();
      await (_api ??= StremioApiClient()).pushProgress(
        authKey: authKey,
        imdb: target.imdb,
        isEpisode: target.isEpisode,
        title: target.title,
        season: target.season,
        episode: target.episode,
        positionMs: positionMs,
        durationMs: durationMs,
        markWatched: markWatched,
        nowIso: iso,
      );
      if (revision == _revision) _lastPushAt = DateTime.now();
      _lastSuccessAt = DateTime.now();
      _lastError = null;
      _lastSkipReason = null;
      ++_successCount;
      final percent = 100 * positionMs / durationMs;
      appLogger.d('Stremio: pushed progress ${target.imdb} @ ${percent.toStringAsFixed(1)}%');
    } catch (e) {
      _lastError = e.toString();
      appLogger.d('Stremio: progress push failed', error: e);
    } finally {
      _pushing = false;
    }
  }
}

/// The resolved sync target for the current playback session.
class _StremioTarget {
  const _StremioTarget({
    required this.imdb,
    required this.isEpisode,
    required this.title,
    this.season,
    this.episode,
  });

  final String imdb;
  final bool isEpisode;
  final String title;
  final int? season;
  final int? episode;
}
