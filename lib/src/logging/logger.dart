/// Log severity levels.
enum LogLevel { debug, info, warn, error }

/// Host-injected logger interface (NFR-OBS-001).
///
/// Core code must not call `print` or `debugPrint` directly (NFR-OBS-002).
/// A `Logger` instance is injected by the host application; a default no-op
/// implementation is used when none is provided.
abstract class Logger {
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  });

  void debug(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.debug, message, context: context);

  void info(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.info, message, context: context);

  void warn(
    String message, [
    Map<String, Object?>? context,
    Object? error,
  ]) =>
      log(LogLevel.warn, message, context: context, error: error);

  void logError(
    String message,
    Object error, [
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  ]) =>
      log(
        LogLevel.error,
        message,
        context: context,
        error: error,
        stackTrace: stackTrace,
      );
}

/// No-op logger used when the host does not inject one.
class NoopLogger extends Logger {
  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    // Intentionally empty.
  }
}
