import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;
import 'package:mocktail/mocktail.dart';

import '../helpers/in_memory_server_storage.dart';
import '../helpers/mock_mcp_server.dart';

/// One device, one connection.
///
/// A device opened from the launcher and the same device named as a `view`
/// origin must ride the SAME link. They used to live in separate registries
/// keyed by the same id — the launcher's [ConnectionManager] and the kernel's
/// client host — so each opened its own. Most of these boards serve a single
/// peer, so the second dial was refused and the device was reachable from one
/// screen and broken in the other, with nothing on screen to explain it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
    registerFallbackValue(<String, dynamic>{});
  });

  late InMemoryServerStorage storage;
  late AppPlayerCoreService core;
  late MockMcpServer server;
  late int dials;

  setUp(() async {
    storage = InMemoryServerStorage();
    await storage.saveServer(_device('esp32.node'));

    server = MockMcpServer();
    server.withResources([
      Resource(
        uri: 'ui://app',
        name: 'App',
        description: '',
        mimeType: 'application/json',
      ),
    ]);
    server.withResourceContent(
        'ui://app', minimalAppDefinition(id: 'esp32-app'));

    // The mock does not stub liveness; a real client reports it.
    when(() => server.client.isConnected).thenReturn(true);

    dials = 0;
    core = AppPlayerCoreService.forTesting(
      connector: (_) async {
        dials++;
        return server.client;
      },
    );
    await core.initialize(
        storage: storage, bundleInstallRoot: '/tmp/core-origin-share');
  });

  tearDown(() async {
    await core.dispose();
  });

  test('a device already open in the launcher is not dialled again for a view',
      () async {
    await core.openAppFromServer('esp32.node');
    expect(dials, 1);

    await core.openSavedDeviceAsOrigin('esp32.node');
    expect(dials, 1,
        reason: 'the origin rides the link the launcher already opened');
  });

  test('a device first opened as a view is reused by the launcher', () async {
    await core.openSavedDeviceAsOrigin('esp32.node');
    expect(dials, 1);

    await core.openAppFromServer('esp32.node');
    expect(dials, 1,
        reason: 'opening the app finds the link the origin already opened');
  });

  test('the same origin asked for twice opens once', () async {
    await core.openSavedDeviceAsOrigin('esp32.node');
    await core.openSavedDeviceAsOrigin('esp32.node');
    expect(dials, 1);
  });

  test('an unknown id is refused rather than dialled', () async {
    await expectLater(
      core.openSavedDeviceAsOrigin('nope.node'),
      throwsA(isA<StateError>()),
    );
    expect(dials, 0);
  });
}

ServerConfig _device(String id) => ServerConfig(
      id: id,
      name: 'ESP32 MCP Node',
      description: 'bench board',
      transportType: TransportType.streamableHttp,
      transportConfig: const {'baseUrl': 'tcp://mcp-esp32.local:6270'},
    );
