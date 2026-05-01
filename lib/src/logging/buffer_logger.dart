import 'log_buffer.dart';
import 'log_entry.dart';
import 'logger.dart';

/// `Logger` adapter that pushes every record into a [LogBuffer] as a
/// [LogSource.core] entry. Pair with a console adapter inside a
/// `CompositeLogger` to keep DevTools output intact while also feeding
/// the in-app log viewer for field reports.
class BufferLogger extends Logger {
  BufferLogger(this._buffer);

  final LogBuffer _buffer;

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _buffer.add(LogEntry.fromCore(
      level: level,
      message: message,
      context: context ?? const <String, Object?>{},
      error: error,
      stackTrace: stackTrace,
    ));
  }
}
