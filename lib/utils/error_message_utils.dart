import '../exceptions/media_server_exceptions.dart';
import '../i18n/strings.g.dart';
import 'app_logger.dart';

/// Logs a load failure once and returns a localized, user-safe message.
///
/// The returned text never includes exception or server response content.
String localizedLoadErrorMessage(Object error, StackTrace stackTrace, {required String context}) {
  appLogger.e('Error loading $context', error: error, stackTrace: stackTrace);

  if (error is MediaServerHttpException) {
    switch (error.type) {
      case MediaServerHttpErrorType.connectionTimeout:
      case MediaServerHttpErrorType.receiveTimeout:
        return t.errors.connectionTimeout(context: context);
      case MediaServerHttpErrorType.connectionError:
        return t.errors.connectionFailed;
      case MediaServerHttpErrorType.cancelled:
        break;
      case MediaServerHttpErrorType.unknown:
        if (error.message.isNotEmpty) {
          return '${t.errors.unableToLoad(context: context)} (${error.message})';
        }
        break;
    }
  } else if (error is MediaServerException && error.message.isNotEmpty) {
    // Sealed hierarchy, but not one of the HTTP-specific cases above --
    // still show the real reason rather than the generic fallback.
    return '${t.errors.unableToLoad(context: context)} (${error.message})';
  }

  return t.errors.unableToLoad(context: context);
}
