import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LogBuffer', () {
    test('TC-LOG-001 add records entry and notifies listeners', () {
      final buffer = LogBuffer();
      var notified = 0;
      buffer.addListener(() => notified++);

      buffer.add(LogEntry(level: LogLevel.info, message: 'first'));

      expect(buffer.entries, hasLength(1));
      expect(buffer.entries.first.message, equals('first'));
      expect(notified, equals(1));
    });

    test('TC-LOG-002 ring evicts oldest beyond capacity', () {
      final buffer = LogBuffer(capacity: 2);
      buffer.add(LogEntry(level: LogLevel.info, message: 'a'));
      buffer.add(LogEntry(level: LogLevel.info, message: 'b'));
      buffer.add(LogEntry(level: LogLevel.info, message: 'c'));

      expect(buffer.entries.map((e) => e.message), equals(['b', 'c']));
    });

    test('TC-LOG-003 clear empties buffer and notifies', () {
      final buffer = LogBuffer();
      buffer.add(LogEntry(level: LogLevel.info, message: 'x'));
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
      buffer.add(LogEntry(
          level: LogLevel.info, message: 'a', context: {'serverId': 's1'}));
      buffer.add(LogEntry(
          level: LogLevel.info, message: 'b', context: {'serverId': 's2'}));
      buffer.add(LogEntry(
          level: LogLevel.info, message: 'c', context: {'serverId': 's1'}));

      final s1 = buffer.withScope('serverId', 's1').toList();
      expect(s1.map((e) => e.message), equals(['a', 'c']));
    });

    test('TC-LOG-006 atLeast filters by minimum level', () {
      final buffer = LogBuffer();
      buffer.add(LogEntry(level: LogLevel.debug, message: 'd'));
      buffer.add(LogEntry(level: LogLevel.info, message: 'i'));
      buffer.add(LogEntry(level: LogLevel.warn, message: 'w'));
      buffer.add(LogEntry(level: LogLevel.error, message: 'e'));

      expect(
        buffer.atLeast(LogLevel.warn).map((e) => e.message),
        equals(['w', 'e']),
      );
    });

    test('TC-LOG-007 capacity must be positive', () {
      expect(() => LogBuffer(capacity: 0), throwsA(isA<AssertionError>()));
    });
  });
}
