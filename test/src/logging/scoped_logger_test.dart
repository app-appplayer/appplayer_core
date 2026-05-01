import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingLogger extends Logger {
  final List<({LogLevel level, String message, Map<String, Object?>? context})>
      records = [];
  final List<({Object? error, StackTrace? stackTrace})> errors = [];

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    records.add((level: level, message: message, context: context));
    errors.add((error: error, stackTrace: stackTrace));
  }
}

void main() {
  group('ScopedLogger', () {
    test('TC-SCOPE-001 injects scope into every log context', () {
      final inner = _RecordingLogger();
      ScopedLogger(inner: inner, scope: {'serverId': 's1'}).info('hello');
      expect(inner.records.first.context, equals({'serverId': 's1'}));
    });

    test('TC-SCOPE-002 caller-supplied keys override scope', () {
      final inner = _RecordingLogger();
      final s = ScopedLogger(
          inner: inner, scope: {'serverId': 's1', 'tenant': 'free'});
      s.info('hi', {'serverId': 'override', 'extra': 1});

      final ctx = inner.records.first.context!;
      expect(ctx['serverId'], 'override');
      expect(ctx['tenant'], 'free');
      expect(ctx['extra'], 1);
    });

    test('TC-SCOPE-003 withScope merges keys', () {
      final inner = _RecordingLogger();
      final base = ScopedLogger(inner: inner, scope: {'a': 1});
      base.withScope({'b': 2}).info('x');
      expect(inner.records.first.context, equals({'a': 1, 'b': 2}));
    });

    test('TC-SCOPE-004 convenience methods forward correct level', () {
      final inner = _RecordingLogger();
      final s = ScopedLogger(inner: inner);
      s.debug('d');
      s.info('i');
      s.warn('w');
      s.logError('e', StateError('x'));
      expect(
        inner.records.map((r) => r.level).toList(),
        equals([
          LogLevel.debug,
          LogLevel.info,
          LogLevel.warn,
          LogLevel.error,
        ]),
      );
    });

    test('TC-SCOPE-005 forwards error and stackTrace', () {
      final inner = _RecordingLogger();
      final err = StateError('boom');
      final st = StackTrace.current;
      ScopedLogger(inner: inner)
          .log(LogLevel.error, 'fail', error: err, stackTrace: st);
      expect(inner.errors.first.error, same(err));
      expect(inner.errors.first.stackTrace, same(st));
    });

    test('TC-SCOPE-006 empty scope leaves caller context intact', () {
      final inner = _RecordingLogger();
      ScopedLogger(inner: inner).info('hi', {'a': 1});
      expect(inner.records.first.context, equals({'a': 1}));
    });
  });

  group('CompositeLogger', () {
    test('TC-COMP-001 fans out to every inner', () {
      final a = _RecordingLogger();
      final b = _RecordingLogger();
      CompositeLogger([a, b]).info('once');
      expect(a.records, hasLength(1));
      expect(b.records, hasLength(1));
    });

    test('TC-COMP-002 forwards error/stackTrace to all inners', () {
      final a = _RecordingLogger();
      final b = _RecordingLogger();
      final err = StateError('boom');
      final st = StackTrace.current;
      CompositeLogger([a, b])
          .log(LogLevel.error, 'fail', error: err, stackTrace: st);
      expect(a.errors.first.error, same(err));
      expect(b.errors.first.stackTrace, same(st));
    });

    test('TC-COMP-003 empty inner list is a safe no-op', () {
      expect(() => CompositeLogger(const []).info('nothing'),
          returnsNormally);
    });
  });

  group('BufferLogger', () {
    test('TC-BUF-001 pushes LogEntry with source=core', () {
      final buffer = LogBuffer();
      BufferLogger(buffer).info('hello', {'k': 'v'});
      expect(buffer.entries, hasLength(1));
      expect(buffer.entries.first.source, LogSource.core);
      expect(buffer.entries.first.message, 'hello');
      expect(buffer.entries.first.context['k'], 'v');
    });

    test('TC-BUF-002 maps LogLevel→McpLogLevel', () {
      final buffer = LogBuffer();
      final logger = BufferLogger(buffer);
      logger.debug('d');
      logger.info('i');
      logger.warn('w');
      logger.logError('e', StateError('x'));
      expect(
        buffer.entries.map((e) => e.level).toList(),
        equals([
          McpLogLevel.debug,
          McpLogLevel.info,
          McpLogLevel.warning,
          McpLogLevel.error,
        ]),
      );
    });
  });

  group('Integration', () {
    test('TC-INT-001 Composite([Console, Buffer]) lands in both', () {
      final recordingConsole = _RecordingLogger();
      final buffer = LogBuffer();
      final logger = CompositeLogger(<Logger>[
        recordingConsole,
        BufferLogger(buffer),
      ]);

      logger.info('once');
      expect(recordingConsole.records, hasLength(1));
      expect(buffer.entries, hasLength(1));
    });

    test('TC-INT-002 LogBuffer.withSource splits core push and fromMcp push',
        () {
      final buffer = LogBuffer();
      BufferLogger(buffer).info('core msg');
      buffer.add(LogEntry.fromMcp(
          serverId: 's1',
          params: {'level': 'warning', 'data': 'mcp msg'}));

      expect(buffer.withSource(LogSource.core).map((e) => e.message),
          equals(['core msg']));
      expect(buffer.withSource(LogSource.mcp).map((e) => e.message),
          equals(['mcp msg']));
    });
  });
}
