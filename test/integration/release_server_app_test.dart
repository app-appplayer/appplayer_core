import 'package:appplayer_core/appplayer_core.dart';
import 'package:appplayer_core/internals.dart' show DashboardOrchestrator;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;
import 'package:mocktail/mocktail.dart';

import '../helpers/in_memory_server_storage.dart';
import '../helpers/mock_mcp_server.dart';

/// A removed app lets go of what it held — and only of what nobody else uses.
///
/// Removing a card used to leave its connection open: measured 2026-09-17, the
/// H723 card was removed by sync and the Mac kept the serial port, so
/// discovery could not reach the board again until the app restarted. The
/// connection is shared (spec 17 §7.6b), so releasing it must not end a
/// composed screen or a dashboard tile still using the same device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
    registerFallbackValue(<String, dynamic>{});
  });

  const id = 'esp32.node';
  late AppPlayerCoreService core;
  late MockMcpServer board;

  setUp(() async {
    final storage = InMemoryServerStorage();
    await storage.saveServer(ServerConfig(
      id: id,
      name: 'ESP32 MCP Node',
      description: 'bench board',
      transportType: TransportType.streamableHttp,
      transportConfig: const {'baseUrl': 'tcp://mcp-esp32.local:6270'},
    ));
    board = MockMcpServer()
      ..withResources([
        Resource(
          uri: 'ui://app',
          name: 'App',
          description: '',
          mimeType: 'application/json',
        ),
      ])
      ..withResourceContent('ui://app', minimalAppDefinition(id: 'esp32-app'));
    when(() => board.client.isConnected).thenReturn(true);
    core = AppPlayerCoreService.forTesting(
      connector: (_) async => board.client,
    );
    await core.initialize(
        storage: storage, bundleInstallRoot: '/tmp/core-release-server-app');
  });

  tearDown(() async {
    await core.dispose();
  });

  bool held() => core.connectionManagerForInternals.hasConnection(id);
  bool hasRuntime() =>
      core.runtimeManagerForInternals.getRuntime(AppHandle.server(id)) != null;

  test('an app nothing else uses releases its connection', () async {
    await core.openAppFromServer(id);
    expect(held(), isTrue, reason: 'premise: open app holds the link');

    final released = await core.releaseServerApp(id);

    expect(released, isTrue);
    expect(held(), isFalse);
    expect(hasRuntime(), isFalse);
    verify(() => board.client.disconnect()).called(1);
  });

  test(
      'a device adopted by the kernel once (composed origin, lending) is still '
      'released, and the adoption is closed with it', () async {
    // Measured 2026-09-17: the Mac had lent the H723 once; counting that
    // adoption as a live consumer kept the removed card's serial port open.
    await core.openAppFromServer(id);
    await core.openSavedDeviceAsOrigin(id);
    expect(core.kernelConnectionsForInternals.map((c) => c.id), contains(id),
        reason: 'premise: the kernel lists the adoption');

    final released = await core.releaseServerApp(id);

    expect(released, isTrue);
    expect(held(), isFalse);
    expect(hasRuntime(), isFalse);
    expect(core.kernelConnectionsForInternals.map((c) => c.id),
        isNot(contains(id)),
        reason: 'the adoption is not left behind as a live consumer');
    verify(() => board.client.disconnect()).called(1);
  });

  test('a dashboard tile watching the device keeps the connection', () async {
    await core.openAppFromServer(id);
    core.runtimeManagerForInternals.getOrCreateRuntime(
        DashboardOrchestrator.deviceSummaryRuntimeHandle(id));

    final released = await core.releaseServerApp(id);

    expect(released, isFalse);
    expect(held(), isTrue);
    verifyNever(() => board.client.disconnect());
  });

  test('closing the session lets go of the connection, as closeApp does',
      () async {
    // Measured 2026-10-02: an entry screen closed on the Mac kept its TCP link
    // to a single-peer device, so the simulator's probe of the same device
    // queued behind it and reported "not found".
    final session = await core.openAppFromServer(id);
    expect(held(), isTrue, reason: 'premise: open app holds the link');

    await session.close();

    expect(held(), isFalse);
    expect(hasRuntime(), isFalse);
    verify(() => board.client.disconnect()).called(1);
  });

  test('closing the session leaves a connection another holder still uses',
      () async {
    final session = await core.openAppFromServer(id);
    core.retainConnection(id, 'lend:phone');

    await session.close();

    expect(held(), isTrue);
    verifyNever(() => board.client.disconnect());
  });

  test('releasing an app that was never opened is harmless', () async {
    expect(await core.releaseServerApp(id), isTrue);
    expect(held(), isFalse);
  });
}
