import 'logger.dart';

/// Single log record captured by [LogBuffer].
///
/// `context` carries the structured key/value pairs the caller passed to
/// the logger (including any keys injected by [ScopedLogger]).
class LogEntry {
  LogEntry({
    DateTime? timestamp,
    required this.level,
    required this.message,
    Map<String, Object?> context = const {},
    this.error,
    this.stackTrace,
  })  : timestamp = timestamp ?? DateTime.now(),
        context = Map<String, Object?>.unmodifiable(context);

  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final Map<String, Object?> context;
  final Object? error;
  final StackTrace? stackTrace;

  /// Convenience accessor for a scope key set by [ScopedLogger]
  /// (e.g. `entry.scope('serverId')`).
  Object? scope(String key) => context[key];
}
