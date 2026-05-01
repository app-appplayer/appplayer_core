import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LogEntry', () {
    test('TC-ENTRY-001 timestamp defaults to ~now', () {
      final before = DateTime.now();
      final entry = LogEntry(
        source: LogSource.core,
        level: McpLogLevel.info,
        message: 'm',
      );
      final after = DateTime.now();

      expect(
        entry.timestamp.isAtSameMomentAs(before) ||
            entry.timestamp.isAfter(before),
        isTrue,
      );
      expect(
        entry.timestamp.isAtSameMomentAs(after) ||
            entry.timestamp.isBefore(after),
        isTrue,
      );
    });

    test('TC-ENTRY-002 explicit timestamp preserved', () {
      final ts = DateTime.utc(2026, 5, 2, 12);
      final entry = LogEntry(
        timestamp: ts,
        source: LogSource.mcp,
        level: McpLogLevel.warning,
        message: 'fixed',
      );
      expect(entry.timestamp, equals(ts));
    });

    test('TC-ENTRY-003 context is unmodifiable', () {
      final entry = LogEntry(
        source: LogSource.core,
        level: McpLogLevel.info,
        message: 'm',
        context: {'k': 1},
      );
      expect(() => (entry.context as dynamic)['k'] = 2,
          throwsUnsupportedError);
    });

    test('TC-ENTRY-004 scope(key) returns context value', () {
      final entry = LogEntry(
        source: LogSource.core,
        level: McpLogLevel.info,
        message: 'm',
        context: {'serverId': 's1'},
      );
      expect(entry.scope('serverId'), equals('s1'));
      expect(entry.scope('missing'), isNull);
    });

    test('TC-ENTRY-005 error/stackTrace preserved', () {
      final err = StateError('boom');
      final st = StackTrace.current;
      final entry = LogEntry(
        source: LogSource.core,
        level: McpLogLevel.error,
        message: 'fail',
        error: err,
        stackTrace: st,
      );
      expect(entry.error, same(err));
      expect(entry.stackTrace, same(st));
    });

    test('TC-ENTRY-006 fromCore maps LogLevel→McpLogLevel + source=core', () {
      final cases = <LogLevel, McpLogLevel>{
        LogLevel.debug: McpLogLevel.debug,
        LogLevel.info: McpLogLevel.info,
        LogLevel.warn: McpLogLevel.warning,
        LogLevel.error: McpLogLevel.error,
      };
      for (final entry in cases.entries) {
        final e =
            LogEntry.fromCore(level: entry.key, message: 'x');
        expect(e.source, LogSource.core);
        expect(e.level, entry.value);
      }
    });

    test('TC-ENTRY-007 fromMcp parses payload + source=mcp + serverId',
        () {
      final entry = LogEntry.fromMcp(
        serverId: 's1',
        params: {'level': 'warning', 'logger': 'auth', 'data': 'expired'},
      );
      expect(entry.source, LogSource.mcp);
      expect(entry.level, McpLogLevel.warning);
      expect(entry.message, equals('[auth] expired'));
      expect(entry.context['serverId'], 's1');
      expect(entry.context['logger'], 'auth');
    });

    test('TC-ENTRY-008 fromMcp unknown level falls back to info', () {
      final entry = LogEntry.fromMcp(
        serverId: 's1',
        params: {'level': 'spaghetti'},
      );
      expect(entry.level, McpLogLevel.info);
    });

    test('TC-ENTRY-008 fromMcp Map data merged into context', () {
      final entry = LogEntry.fromMcp(
        serverId: 's1',
        params: {
          'level': 'info',
          'data': {'key': 'value', 'count': 3},
        },
      );
      expect(entry.context['key'], 'value');
      expect(entry.context['count'], 3);
    });
  });
}
