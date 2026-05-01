import 'logger.dart';

/// Logger decorator that injects a fixed [scope] map into every log
/// call's `context`. Caller-supplied keys override scope keys on
/// collision. Typical scope: `{serverId, handle}` so downstream filters
/// can isolate logs per connection / app.
class ScopedLogger extends Logger {
  ScopedLogger({
    required Logger inner,
    Map<String, Object?> scope = const <String, Object?>{},
  })  : _inner = inner,
        _scope = Map<String, Object?>.unmodifiable(scope);

  final Logger _inner;
  final Map<String, Object?> _scope;

  ScopedLogger withScope(Map<String, Object?> additional) {
    return ScopedLogger(
      inner: _inner,
      scope: <String, Object?>{..._scope, ...additional},
    );
  }

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _inner.log(
      level,
      message,
      context: <String, Object?>{
        ..._scope,
        if (context != null) ...context,
      },
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// Fan-out logger — every record is forwarded to each inner logger.
/// Typical use: `CompositeLogger([ConsoleLogger, BufferLogger])` so a
/// single Core diagnostic call lands in DevTools (development) AND the
/// in-app `LogBuffer` (field report).
class CompositeLogger extends Logger {
  CompositeLogger(List<Logger> inners)
      : _inners = List<Logger>.unmodifiable(inners);

  final List<Logger> _inners;

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    for (final inner in _inners) {
      inner.log(
        level,
        message,
        context: context,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
