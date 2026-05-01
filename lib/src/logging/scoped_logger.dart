import 'logger.dart';

/// Logger decorator that injects a fixed [scope] map into every log call's
/// `context` so downstream consumers (e.g. `LogBuffer` viewers) can filter
/// by scope (typically `serverId`, `handle`, `bundleId`, `tenant`).
///
/// Inner logger receives the merged context. Caller-supplied keys take
/// precedence over scope keys when they collide.
class ScopedLogger extends Logger {
  ScopedLogger({
    required Logger inner,
    Map<String, Object?> scope = const <String, Object?>{},
  })  : _inner = inner,
        _scope = Map<String, Object?>.unmodifiable(scope);

  final Logger _inner;
  final Map<String, Object?> _scope;

  /// Returns a new [ScopedLogger] wrapping the same inner logger with
  /// [additional] keys merged into the existing scope.
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
    final Map<String, Object?> merged = <String, Object?>{
      ..._scope,
      if (context != null) ...context,
    };
    _inner.log(
      level,
      message,
      context: merged,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// Logger that fans out every record to multiple inner loggers
/// (typical use: a console adapter and a [LogBuffer] adapter side-by-side).
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
