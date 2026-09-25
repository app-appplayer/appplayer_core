import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;
import 'package:mocktail/mocktail.dart';

import '../helpers/in_memory_server_storage.dart';
import '../helpers/mock_mcp_server.dart';

/// An open server app reads its pages through the connection the device has
/// **now**, not the one it had when the app was opened.
///
/// A reconnect replaces the client. The page loader handed to the runtime used
/// to hold the client from open time, so after the ESP32 dropped and came back
/// (`Reconnect succeeded`) every page read still failed with "Transport
/// disconnected" — measured 2026-09-17 on macOS, the app stuck on
/// "Failed to load page" until the app was restarted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
    registerFallbackValue(<String, dynamic>{});
  });

  const id = 'esp32.node';
  const page = 'ui://pages/settings';

  late AppPlayerCoreService core;
  late MockMcpServer before;
  late MockMcpServer after;
  late List<MockMcpServer> dialQueue;

  MockMcpServer board() {
    final s = MockMcpServer()
      ..withResources([
        Resource(
          uri: 'ui://app',
          name: 'App',
          description: '',
          mimeType: 'application/json',
        ),
      ])
      ..withResourceContent('ui://app', minimalAppDefinition(id: 'esp32-app'));
    when(() => s.client.isConnected).thenReturn(true);
    return s;
  }

  setUp(() async {
    final storage = InMemoryServerStorage();
    await storage.saveServer(ServerConfig(
      id: id,
      name: 'ESP32 MCP Node',
      description: 'bench board',
      transportType: TransportType.streamableHttp,
      transportConfig: const {'baseUrl': 'tcp://mcp-esp32.local:6270'},
    ));
    before = board();
    after = board();
    dialQueue = [before, after];
    core = AppPlayerCoreService.forTesting(
      connector: (_) async => dialQueue.removeAt(0).client,
    );
    await core.initialize(
        storage: storage, bundleInstallRoot: '/tmp/core-page-reconnect');
    await core.openAppFromServer(id);
  });

  tearDown(() async {
    await core.dispose();
  });

  Future<Map<String, dynamic>> readPage(String uri) async {
    final runtime =
        core.runtimeManagerForInternals.getRuntime(AppHandle.server(id))!;
    final result = await runtime.engine.routeManager!.pageLoader(uri);
    return Map<String, dynamic>.from(result as Map);
  }

  test('a page read after a reconnect goes through the new connection',
      () async {
    when(() => before.client.readResource(page))
        .thenThrow(McpError('Transport disconnected'));
    after.withResourceContent(page, {'type': 'page', 'title': 'Settings'});

    await core.connectionManagerForInternals.reconnect(id);

    final got = await readPage(page);
    expect(got['title'], 'Settings');
    verifyNever(() => before.client.readResource(page));
  });

  test('a read cut by a drop is retried once the reconnect has replaced the '
      'client', () async {
    after.withResourceContent(page, {'type': 'page', 'title': 'Settings'});
    when(() => before.client.readResource(page)).thenAnswer((_) async {
      await core.connectionManagerForInternals.reconnect(id);
      throw McpError('Transport disconnected');
    });

    final got = await readPage(page);
    expect(got['title'], 'Settings');
  });

  test('a failure on a connection that did not change is not retried',
      () async {
    var reads = 0;
    when(() => before.client.readResource(page)).thenAnswer((_) async {
      reads++;
      throw McpError('Resource not found', code: -32002);
    });

    await expectLater(readPage(page), throwsA(isA<McpError>()));
    expect(reads, 1, reason: "the server's own answer is not masked");
    expect(dialQueue, hasLength(1), reason: 'nothing dialled again');
  });
}
