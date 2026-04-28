import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState;
import 'package:mocktail/mocktail.dart';

import '../helpers/in_memory_server_storage.dart';
import '../helpers/mock_mcp_server.dart';
import '../helpers/mocks.dart';

ServerConfig _device(String id, {Map<String, dynamic>? metadata}) =>
    ServerConfig(
      id: id,
      name: 'Device $id',
      description: 'd',
      transportType: TransportType.stdio,
      transportConfig: const {'command': 'dart'},
      metadata: metadata,
    );

MockMcpServer _makeDeviceServer(String id) {
  final s = MockMcpServer();
  s.withResources([
    Resource(
      uri: 'ui://views/summary',
      name: 'summary',
      description: '',
    ),
    Resource(uri: 'ui://app', name: 'App', description: ''),
  ]);
  s.withResourceContent(
      'ui://views/summary', minimalSummaryDefinition(id: id));
  s.withResourceContent('ui://app', minimalAppDefinition(id: id));
  return s;
}

void main() {
  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
  });

  group('Integration: Dashboard end-to-end', () {
    late InMemoryServerStorage storage;
    late AppPlayerCoreService core;
    late Map<String, MockMcpServer> servers;

    setUp(() async {
      storage = InMemoryServerStorage();
      await storage.saveServer(_device('d1'));
      await storage.saveServer(_device('d2'));

      servers = {
        'd1': _makeDeviceServer('d1'),
        'd2': _makeDeviceServer('d2'),
      };

      final queue = <MockClient>[
        servers['d1']!.client,
        servers['d2']!.client,
      ];
      var idx = 0;

      core = AppPlayerCoreService.forTesting(
        connector: (_) async => queue[idx++],
      );
      await core.initialize(storage: storage, bundleInstallRoot: '/tmp/core-it-bundles');
    });

    tearDown(() async {
      await core.dispose();
    });

    test('IT-DASH-001: synthesized bundle mounts both device slots',
        () async {
      final session = await core.openDashboard(
        const DashboardBundleRef(
          bundleId: 'auto-1',
          source: BundleSource.synthesized,
        ),
        ['d1', 'd2'],
      );

      expect(session.handle, const AppHandle.bundle('auto-1'));

      // Verify main dashboard runtime state via internals.
      final runtime = core.runtimeManagerForInternals
          .getRuntime(const AppHandle.bundle('dashboard:auto-1'))!;
      expect(runtime.isInitialized, isTrue);
      expect(runtime.stateManager.get<String>('slot.slot-0.deviceId'),
          'd1');
      expect(runtime.stateManager.get<String>('slot.slot-1.deviceId'),
          'd2');

      verify(() => servers['d1']!.client.readResource('ui://views/summary'))
          .called(1);
      verify(() => servers['d2']!.client.readResource('ui://views/summary'))
          .called(1);
    });

    test('IT-DASH-002: closeDashboard removes main runtime, keeps devices',
        () async {
      await core.openDashboard(
        const DashboardBundleRef(
          bundleId: 'auto-2',
          source: BundleSource.synthesized,
        ),
        ['d1', 'd2'],
      );

      expect(core.connections['d1']!.state, ConnectionState.connected);

      await core.closeDashboard();
      expect(core.connections['d1']!.state, ConnectionState.connected);
    });
  });
}
