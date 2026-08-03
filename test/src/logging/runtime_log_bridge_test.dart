// The UI DSL runtime's diagnostics reach the host.
//
// konpi went looking for a warning the runtime emits — a theme role declared
// and dropped — and found it in none of the places a host can see: the app's
// stdout, the run console, and AppPlayer's own log screen were all empty. It
// was reaching `dart:developer` and stopping there, so the only reader was
// whoever had DevTools open. The message is written for the person who wrote
// the document, and that person is looking at the app.
//
// `stdout` is not an alternative: on a stdio MCP connection it carries the
// protocol.

import 'package:appplayer_core/appplayer_core.dart';
import 'package:appplayer_core/internals.dart' show LogEntry, LogSource;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show MCPLogger, MCPLogRecord;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';
import '../../helpers/mocks.dart';

void main() {
  late AppPlayerCoreService core;
  late InMemoryServerStorage storage;

  setUp(() {
    storage = InMemoryServerStorage();
    core = AppPlayerCoreService.forTesting(connector: (_) async => MockClient());
  });

  tearDown(() async {
    await core.dispose();
    MCPLogger.onRecord = null;
  });

  test('a host that asks for runtime logs receives them', () async {
    final received = <MCPLogRecord>[];
    await core.initialize(
      storage: storage,
      bundleInstallRoot: '/tmp/core-log-bridge',
      onRuntimeLog: received.add,
    );

    MCPLogger('probe').warning('theme.color.background is a legacy role');

    expect(received, hasLength(1));
    expect(received.single.level, 'WARN');
    expect(received.single.logger, 'probe');
    expect(received.single.message, contains('legacy role'));
  });

  test('a host that does not ask is not charged for it', () async {
    await core.initialize(
      storage: storage,
      bundleInstallRoot: '/tmp/core-log-bridge-2',
    );
    expect(MCPLogger.onRecord, isNull);
    expect(() => MCPLogger('probe').warning('w'), returnsNormally);
  });

  test('dispose removes this service\'s bridge and nothing else', () async {
    // The hook is static. A service that cleared it unconditionally would
    // silence a handler its host installed directly, or one belonging to
    // another instance.
    await core.initialize(
      storage: storage,
      bundleInstallRoot: '/tmp/core-log-bridge-3',
      onRuntimeLog: (_) {},
    );
    expect(MCPLogger.onRecord, isNotNull);
    await core.dispose();
    expect(MCPLogger.onRecord, isNull);

    var hostSaw = 0;
    MCPLogger.onRecord = (_) => hostSaw++;
    final second = AppPlayerCoreService.forTesting(
      connector: (_) async => MockClient(),
    );
    await second.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: '/tmp/core-log-bridge-4',
    );
    await second.dispose();
    MCPLogger('probe').warning('still heard');
    expect(hostSaw, 1,
        reason: "a service that installed nothing must not clear the host's");
  });

  test('a runtime record becomes a log entry the viewer can show', () {
    // The viewer filters by source and level; a runtime record has to arrive
    // with both rather than as an untagged line.
    final entry = LogEntry.fromRuntime(
      level: 'WARN',
      logger: 'ThemeManager',
      message: 'theme.color.background is a legacy role',
    );
    expect(entry.source, LogSource.runtime);
    expect(entry.level.name, 'warning');
    expect(entry.message, contains('[ThemeManager]'));
  });

  test('every runtime level maps onto a viewer level', () {
    const pairs = <String, String>{
      'DEBUG': 'debug',
      'INFO': 'info',
      'WARN': 'warning',
      'ERROR': 'error',
    };
    pairs.forEach((runtime, mcp) {
      expect(
        LogEntry.fromRuntime(level: runtime, logger: 'l', message: 'm')
            .level
            .name,
        mcp,
      );
    });
  });
}
