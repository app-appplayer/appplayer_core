import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

LogEntry _entry(McpLogLevel level, String message,
    {LogSource source = LogSource.core,
    Map<String, Object?> context = const {}}) {
  return LogEntry(
    source: source,
    level: level,
    message: message,
    context: context,
  );
}

void main() {
  group('LogBuffer', () {
    test('TC-LOG-001 add records entry and notifies listeners', () {
      final buffer = LogBuffer();
      var notified = 0;
      buffer.addListener(() => notified++);

      buffer.add(_entry(McpLogLevel.info, 'first'));

      expect(buffer.entries, hasLength(1));
      expect(notified, equals(1));
    });

    test('TC-LOG-002 ring evicts oldest beyond capacity', () {
      final buffer = LogBuffer(capacity: 2);
      buffer.add(_entry(McpLogLevel.info, 'a'));
      buffer.add(_entry(McpLogLevel.info, 'b'));
      buffer.add(_entry(McpLogLevel.info, 'c'));

      expect(buffer.entries.map((e) => e.message), equals(['b', 'c']));
    });

    test('TC-LOG-003 clear empties buffer and notifies', () {
      final buffer = LogBuffer();
      buffer.add(_entry(McpLogLevel.info, 'x'));
      var notified = 0;
      buffer.addListener(() => notified++);

      buffer.clear();
      expect(buffer.entries, isEmpty);
      expect(notified, equals(1));
    });

    test('TC-LOG-004 clear no-op on empty does not notify', () {
      final buffer = LogBuffer();
      var notified = 0;
      buffer.addListener(() => notified++);
      buffer.clear();
      expect(notified, equals(0));
    });

    test('TC-LOG-005 withScope filters by context key', () {
      final buffer = LogBuffer();
      buffer.add(_entry(McpLogLevel.info, 'a', context: {'serverId': 's1'}));
      buffer.add(_entry(McpLogLevel.info, 'b', context: {'serverId': 's2'}));
      buffer.add(_entry(McpLogLevel.info, 'c', context: {'serverId': 's1'}));

      expect(
        buffer.withScope('serverId', 's1').map((e) => e.message),
        equals(['a', 'c']),
      );
    });

    test('TC-LOG-006 atLeast filters by McpLogLevel index', () {
      final buffer = LogBuffer();
      buffer.add(_entry(McpLogLevel.debug, 'd'));
      buffer.add(_entry(McpLogLevel.info, 'i'));
      buffer.add(_entry(McpLogLevel.warning, 'w'));
      buffer.add(_entry(McpLogLevel.critical, 'c'));

      expect(
        buffer.atLeast(McpLogLevel.warning).map((e) => e.message),
        equals(['w', 'c']),
      );
    });

    test('TC-LOG-007 capacity must be positive', () {
      expect(() => LogBuffer(capacity: 0), throwsA(isA<AssertionError>()));
    });

    test('TC-LOG-008 filter accepts arbitrary predicate', () {
      final buffer = LogBuffer();
      buffer.add(_entry(McpLogLevel.info, 'short'));
      buffer.add(_entry(McpLogLevel.info, 'a longer one'));
      expect(
        buffer.filter((e) => e.message.length > 6).map((e) => e.message),
        equals(['a longer one']),
      );
    });

    test('TC-LOG-009 entries snapshot is unmodifiable', () {
      final buffer = LogBuffer();
      buffer.add(_entry(McpLogLevel.info, 'a'));
      expect(
        () => (buffer.entries as dynamic)
            .add(_entry(McpLogLevel.info, 'b')),
        throwsUnsupportedError,
      );
    });

    test('TC-LOG-010 notifies multiple listeners', () {
      final buffer = LogBuffer();
      var a = 0;
      var b = 0;
      buffer.addListener(() => a++);
      buffer.addListener(() => b++);
      buffer.add(_entry(McpLogLevel.info, 'x'));
      expect(a, equals(1));
      expect(b, equals(1));
    });

    test('TC-LOG-011 removeListener stops notifications', () {
      final buffer = LogBuffer();
      var n = 0;
      void listener() => n++;
      buffer.addListener(listener);
      buffer.add(_entry(McpLogLevel.info, '1'));
      buffer.removeListener(listener);
      buffer.add(_entry(McpLogLevel.info, '2'));
      expect(n, equals(1));
    });

    test('TC-LOG-012 withSource splits core/mcp', () {
      final buffer = LogBuffer();
      buffer.add(_entry(McpLogLevel.info, 'core1'));
      buffer.add(_entry(McpLogLevel.info, 'mcp1', source: LogSource.mcp));
      buffer.add(_entry(McpLogLevel.info, 'core2'));

      expect(
        buffer.withSource(LogSource.core).map((e) => e.message),
        equals(['core1', 'core2']),
      );
      expect(
        buffer.withSource(LogSource.mcp).map((e) => e.message),
        equals(['mcp1']),
      );
    });
  });
}
