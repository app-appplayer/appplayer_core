import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingLogger extends Logger {
  final List<({LogLevel level, String message, Map<String, Object?>? context})>
      records = [];

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    records.add((level: level, message: message, context: context));
  }
}

void main() {
  group('ScopedLogger', () {
    test('TC-SCOPE-001 injects scope into every log context', () {
      final inner = _RecordingLogger();
      final scoped = ScopedLogger(inner: inner, scope: {'serverId': 's1'});

      scoped.info('hello');

      expect(inner.records, hasLength(1));
      expect(inner.records.first.context, equals({'serverId': 's1'}));
    });

    test('TC-SCOPE-002 caller-supplied keys take precedence over scope', () {
      final inner = _RecordingLogger();
      final scoped = ScopedLogger(
          inner: inner, scope: {'serverId': 's1', 'tenant': 'free'});

      scoped.info('hi', {'serverId': 'override', 'extra': 1});

      final ctx = inner.records.first.context!;
      expect(ctx['serverId'], equals('override'));
      expect(ctx['tenant'], equals('free'));
      expect(ctx['extra'], equals(1));
    });

    test('TC-SCOPE-003 withScope merges additional keys', () {
      final inner = _RecordingLogger();
      final base = ScopedLogger(inner: inner, scope: {'serverId': 's1'});
      final nested = base.withScope({'handle': 'h1'});

      nested.warn('w');

      expect(
        inner.records.first.context,
        equals({'serverId': 's1', 'handle': 'h1'}),
      );
    });
  });

  group('CompositeLogger', () {
    test('TC-COMP-001 fans out to every inner logger', () {
      final a = _RecordingLogger();
      final b = _RecordingLogger();
      final composite = CompositeLogger([a, b]);

      composite.info('once');

      expect(a.records, hasLength(1));
      expect(b.records, hasLength(1));
    });
  });

  group('LogBuffer × ScopedLogger integration', () {
    test('TC-INT-001 scoped logger feeds buffer with scope-tagged entries',
        () {
      final buffer = LogBuffer();
      final bufferLogger = _BufferLogger(buffer);
      final scoped =
          ScopedLogger(inner: bufferLogger, scope: {'serverId': 's1'});

      scoped.info('connected');
      scoped.warn('flaky');

      expect(buffer.entries, hasLength(2));
      expect(
        buffer.withScope('serverId', 's1').map((e) => e.message),
        equals(['connected', 'flaky']),
      );
    });
  });
}

class _BufferLogger extends Logger {
  _BufferLogger(this._buffer);
  final LogBuffer _buffer;

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _buffer.add(LogEntry(
      level: level,
      message: message,
      context: context ?? const {},
      error: error,
      stackTrace: stackTrace,
    ));
  }
}
