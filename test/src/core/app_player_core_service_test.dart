import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/in_memory_server_storage.dart';
import '../../helpers/mocks.dart';

ServerConfig _server([String id = 's1']) => ServerConfig(
      id: id,
      name: 'Name $id',
      description: 'd',
      transportType: TransportType.stdio,
      transportConfig: const {'command': 'dart'},
    );

class _FakeTenantSource implements TenantSource {
  _FakeTenantSource(this._map);
  final Map<String, TenantContext?> _map;
  @override
  Future<TenantContext?> resolve(String appCode) async => _map[appCode];
}

AppPlayerCoreService _testCore() =>
    AppPlayerCoreService.forTesting(connector: (_) async => MockClient());

void main() {
  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
  });

  group('AppPlayerCoreService (MOD-CORE-001)', () {
    test('TC-CORE-001: initialize exposes public surface', () async {
      final core = _testCore();
      await core.initialize(storage: InMemoryServerStorage(), bundleInstallRoot: '/tmp/core-test-bundles');
      expect(core.connections, isEmpty);
      expect(core.currentTenant, isNull);
      await core.dispose();
    });

    test('TC-CORE-021: mcp.* client tools registered on the dispatcher',
        () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-test-bundles',
      );
      final names = core.toolDispatcherForInternals.inProcessToolNames;
      // bk.* present ⇒ the kernel booted; mcp.* present ⇒ the mcp_client
      // capability (app-driven outbound) is wired through the same path.
      expect(names.any((n) => n.startsWith('bk.')), isTrue);
      expect(names, contains('mcp.connect'));
      expect(names, contains('mcp.call_tool'));
      await core.dispose();
    });

    test('TC-CORE-002: double initialize throws', () async {
      final core = _testCore();
      await core.initialize(storage: InMemoryServerStorage(), bundleInstallRoot: '/tmp/core-test-bundles');
      await expectLater(
        core.initialize(storage: InMemoryServerStorage(), bundleInstallRoot: '/tmp/core-test-bundles'),
        throwsA(isA<StateError>()),
      );
      await core.dispose();
    });

    test('TC-CORE-012: methods before initialize throw', () async {
      final core = _testCore();
      await expectLater(
        core.openAppFromServer('x'),
        throwsA(isA<StateError>()),
      );
    });

    test('TC-CORE-005: openAppFromServer unknown server', () async {
      final core = _testCore();
      await core.initialize(storage: InMemoryServerStorage(), bundleInstallRoot: '/tmp/core-test-bundles');
      await expectLater(
        core.openAppFromServer('nope'),
        throwsA(isA<ServerNotFoundException>()),
      );
      await core.dispose();
    });

    test('TC-CORE-006: tenant denies connect', () async {
      final storage = InMemoryServerStorage();
      await storage.saveServer(_server('s1'));

      final core = _testCore();
      await core.initialize(
        storage: storage,
        bundleInstallRoot: '/tmp/core-test-bundles',
        tenantSource: _FakeTenantSource({
          'A': const TenantContext(
            appCode: 'A',
            allowedServerIds: {'other'},
            allowedBundleIds: {},
          ),
        }),
      );
      await core.applyTenant('A');

      await expectLater(
        core.openAppFromServer('s1'),
        throwsA(isA<TenantAccessDeniedException>()),
      );
      await core.dispose();
    });

    test('TC-CORE-010: applyTenant then clearTenant', () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-test-bundles',
        tenantSource: _FakeTenantSource({
          'A': const TenantContext(
            appCode: 'A',
            allowedServerIds: {},
            allowedBundleIds: {},
          ),
        }),
      );
      final ctx = await core.applyTenant('A');
      expect(core.currentTenant, same(ctx));
      await core.clearTenant();
      expect(core.currentTenant, isNull);
      await core.dispose();
    });

    test('TC-CORE-011: dispose resets state', () async {
      final core = _testCore();
      await core.initialize(storage: InMemoryServerStorage(), bundleInstallRoot: '/tmp/core-test-bundles');
      await core.dispose();
      await expectLater(
        core.openAppFromServer('x'),
        throwsA(isA<StateError>()),
      );
    });

    test('TC-CORE-007: openAppFromServer connection failure propagates',
        () async {
      final storage = InMemoryServerStorage();
      await storage.saveServer(_server('s1'));

      final core = AppPlayerCoreService.forTesting(
        connector: (_) async => throw StateError('cannot connect'),
      );
      await core.initialize(storage: storage, bundleInstallRoot: '/tmp/core-test-bundles');
      await expectLater(
        core.openAppFromServer('s1'),
        throwsA(isA<ConnectionFailedException>()),
      );
      await core.dispose();
    });

    test('TC-CORE-013: settings before initialize throws', () {
      final core = _testCore();
      expect(() => core.settings, throwsA(isA<StateError>()));
    });

    test('TC-CORE-014: settings defaults to InMemorySettingsStore', () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-test-bundles',
      );
      expect(core.settings, isA<InMemorySettingsStore>());
      await core.dispose();
    });

    test('TC-CORE-015: settings can be injected via initialize', () async {
      final core = _testCore();
      final injected = InMemorySettingsStore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-test-bundles',
        settingsStore: injected,
      );
      expect(core.settings, same(injected));
      await core.dispose();
    });

    test('TC-CORE-016: initialize accepts custom workspaceId', () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-test-bundles',
        workspaceId: 'appplayer.standard',
      );
      // No public reader for workspaceId, but a clean dispose proves
      // brain_kernel boot + teardown both ran.
      await core.dispose();
    });

    test('TC-CORE-017: setActiveSession before initialize throws', () {
      final core = _testCore();
      expect(
        () => core.setActiveSession(const AppHandle.bundle('x')),
        throwsA(isA<StateError>()),
      );
    });

    test('TC-CORE-018: setActiveSession with bundle / server / null',
        () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-test-bundles',
      );
      // Three branches: bundle handle, server handle, null.
      core.setActiveSession(const AppHandle.bundle('com.example.a'));
      core.setActiveSession(const AppHandle.server('s1'));
      core.setActiveSession(null);
      await core.dispose();
    });

    test('TC-CORE-019: server CRUD passthrough (list / save / get / delete)',
        () async {
      final storage = InMemoryServerStorage();
      final core = _testCore();
      await core.initialize(
        storage: storage,
        bundleInstallRoot: '/tmp/core-test-bundles',
      );
      // list — empty.
      expect(await core.listServers(), isEmpty);

      // save → list contains it.
      await core.saveServer(_server('s1'));
      expect((await core.listServers()).single.id, 's1');

      // get → matches.
      expect((await core.getServer('s1'))?.id, 's1');
      expect(await core.getServer('missing'), isNull);

      // delete → list empty again.
      await core.deleteServer('s1');
      expect(await core.listServers(), isEmpty);
      await core.dispose();
    });

    test('TC-CORE-020: setMcpLoggingLevel returns false when no client',
        () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-test-bundles',
      );
      expect(
        await core.setMcpLoggingLevel('never', McpLogLevel.info),
        isFalse,
      );
      await core.dispose();
    });
  });
}
