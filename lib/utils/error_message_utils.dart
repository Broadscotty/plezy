import '../exceptions/media_server_exceptions.dart';
import '../i18n/strings.g.dart';
import '../services/stremio/real_debrid_client.dart';
import '../services/stremio/stremio_addon_client.dart';
import 'app_logger.dart';

/// Logs a load failure once and returns a localized, user-safe message.
///
/// The returned text never includes exception or server response content,
/// with one deliberate exception: [StremioAddonException] and
/// [RealDebridException] messages are shown directly, because those two
/// types are constructed pre-redacted at the source (see
/// StremioAddonClient._redactForDisplay) specifically so they're safe to
/// surface -- unlike MediaServerHttpException.unknown, which can carry a raw
/// Plex/Jellyfin server response body and must never be shown as-is.
String localizedLoadErrorMessage(Object error, StackTrace stackTrace, {required String context}) {
  appLogger.e('Error loading $context', error: error, stackTrace: stackTrace);

  if (error is StremioAddonException || error is RealDebridException) {
    return '${t.errors.unableToLoad(context: context)} (${error.toString().replaceFirst(RegExp(r'^\w+Exception: '), '')})';
  }

  if (error is MediaServerHttpException) {
    switch (error.type) {
      case MediaServerHttpErrorType.connectionTimeout:
      case MediaServerHttpErrorType.receiveTimeout:
        return t.errors.connectionTimeout(context: context);
      case MediaServerHttpErrorType.connectionError:
        return t.errors.connectionFailed;
      case MediaServerHttpErrorType.cancelled:
      case MediaServerHttpErrorType.unknown:
        break;
    }
  }

  return t.errors.unableToLoad(context: context);
}
