import 'package:appplayer_core/appplayer_core.dart';
import 'package:appplayer_core/internals.dart' show DashboardOrchestrator;
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

    test(
        'IT-DASH-003: a device\'s state is readable and writable at '
        '`slot.<id>.<path>` (§3.5.5)', () async {
      // The point of Dashboard Mode over a host-arranged grid: one device\'s
      // reading and another device\'s control are two paths in one state tree,
      // so a plain binding expresses the relationship between them. Before the
      // bridge a slot carried only `deviceId`, and a dashboard could place a
      // device but never react to one.
      await core.openDashboard(
        const DashboardBundleRef(
          bundleId: 'auto-bridge',
          source: BundleSource.synthesized,
        ),
        ['d1', 'd2'],
      );

      final dash = core.runtimeManagerForInternals
          .getRuntime(const AppHandle.bundle('dashboard:auto-bridge'))!;
      final deviceA = core.runtimeManagerForInternals.getRuntime(
        DashboardOrchestrator.deviceSummaryRuntimeHandle('d1'),
      )!;
      final deviceB = core.runtimeManagerForInternals.getRuntime(
        DashboardOrchestrator.deviceSummaryRuntimeHandle('d2'),
      )!;

      // Read: the device's value appears under its slot.
      deviceA.stateManager.set('temperature', 8);
      await Future<void>.delayed(Duration.zero);
      expect(dash.stateManager.get<int>('slot.slot-0.temperature'), 8,
          reason: 'a device reading must be visible to the dashboard');

      // Write: the dashboard controls the *other* device by path alone.
      dash.stateManager.set('slot.slot-1.heating', true);
      await Future<void>.delayed(Duration.zero);
      expect(deviceB.stateManager.get<bool>('heating'), isTrue,
          reason: 'writing a slot path must reach the bound device');

      // The host's own fields are not the device's to overwrite.
      deviceA.stateManager.set('deviceId', 'spoofed');
      await Future<void>.delayed(Duration.zero);
      expect(dash.stateManager.get<String>('slot.slot-0.deviceId'), 'd1',
          reason: 'a device must not be able to rewrite the binding');
    });

    test('IT-DASH-004: the synthesized layout draws its slots', () async {
      // The layout is what a dashboard bundle designs; `slot` had no factory,
      // so a bundle could describe a dashboard the runtime could not draw.
      // Registration happens before `initialize`, which is also what lets the
      // document validate — the runtime checks its widget registry before
      // calling a type unknown.
      final session = await core.openDashboard(
        const DashboardBundleRef(
          bundleId: 'auto-draw',
          source: BundleSource.synthesized,
        ),
        ['d1'],
      );

      final dash = core.runtimeManagerForInternals
          .getRuntime(const AppHandle.bundle('dashboard:auto-draw'))!;
      expect(dash.isInitialized, isTrue,
          reason: 'a layout containing `slot` must pass schema validation');
      expect(session.handle, const AppHandle.bundle('auto-draw'));
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
