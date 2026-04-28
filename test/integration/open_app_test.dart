import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;
import 'package:mocktail/mocktail.dart';

import '../helpers/in_memory_server_storage.dart';
import '../helpers/mock_mcp_server.dart';

ServerConfig _server(String id) => ServerConfig(
      id: id,
      name: 'Server $id',
      description: 'd',
      transportType: TransportType.stdio,
      transportConfig: const {'command': 'dart'},
    );

void main() {
  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
    registerFallbackValue(<String, dynamic>{});
  });

  group('Integration: openAppFromServer end-to-end', () {
    late InMemoryServerStorage storage;
    late AppPlayerCoreService core;
    late MockMcpServer server;

    setUp(() async {
      storage = InMemoryServerStorage();
      await storage.saveServer(_server('s1'));

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
          'ui://app', minimalAppDefinition(id: 's1-app'));
      server.withTools(['incr']);
      server.withToolResponse('incr', {'count': 7});

      core = AppPlayerCoreService.forTesting(
        connector: (_) async => server.client,
      );
      await core.initialize(storage: storage, bundleInstallRoot: '/tmp/core-it-bundles');
    });

    tearDown(() async {
      await core.dispose();
    });

    test('IT-001: UC-001 — openAppFromServer connects, loads, initializes',
        () async {
      final session = await core.openAppFromServer('s1');
      expect(session.handle, const AppHandle.server('s1'));
      expect(session.source, AppSource.server);
      expect(core.connections['s1']!.state, ConnectionState.connected);

      final saved = await storage.getById('s1');
      expect(saved!.lastConnectedAt, isNotNull);

      verify(() => server.client.onNotification(
            'notifications/resources/updated',
            any(),
          )).called(1);
    });

    test('IT-002: UC-002 — second openAppFromServer reuses connection',
        () async {
      await core.openAppFromServer('s1');
      await core.openAppFromServer('s1');

      verify(() => server.client.listResources()).called(1);
      verify(() => server.client.onNotification(any(), any())).called(1);
    });

    test('IT-003: tool dispatch folds JSON into runtime state', () async {
      await core.openAppFromServer('s1');
      final runtime = core.runtimeManagerForInternals
          .getRuntime(const AppHandle.server('s1'))!;
      await core.toolDispatcherForInternals.call(
        client: server.client,
        runtime: runtime,
        tool: 'incr',
        params: const {},
      );
      expect(runtime.stateManager.get<int>('count'), 7);
    });

    test('IT-004: resource subscribe writes initial state', () async {
      server.withSubscription();
      server.withResourceContent('res://live', {'temperature': 42});

      await core.openAppFromServer('s1');
      final runtime = core.runtimeManagerForInternals
          .getRuntime(const AppHandle.server('s1'))!;
      await core.resourceSubscriberForInternals.subscribe(
        client: server.client,
        runtime: runtime,
        uri: 'res://live',
        binding: 'temperature',
      );

      verify(() => server.client.subscribeResource('res://live')).called(1);
      expect(runtime.stateManager.get<int>('temperature'), 42);
    });

    test('IT-005: UC-006 — tenant denies openAppFromServer outside allowlist',
        () async {
      final fake = _FakeTenantSource({
        'A': const TenantContext(
          appCode: 'A',
          allowedServerIds: {'other-server'},
          allowedBundleIds: {},
        ),
      });

      final restricted = AppPlayerCoreService.forTesting(
        connector: (_) async => server.client,
      );
      await restricted.initialize(
        storage: storage,
        bundleInstallRoot: '/tmp/core-it-bundles',
        tenantSource: fake,
      );
      addTearDown(restricted.dispose);

      await restricted.applyTenant('A');
      await expectLater(
        restricted.openAppFromServer('s1'),
        throwsA(isA<TenantAccessDeniedException>()),
      );

      await restricted.clearTenant();
      final session = await restricted.openAppFromServer('s1');
      expect(session.source, AppSource.server);
    });

    test('IT-006: dispose releases all connections and runtimes',
        () async {
      await core.openAppFromServer('s1');
      expect(core.connections, isNotEmpty);

      await core.dispose();
      expect(core.connections, isEmpty);

      await expectLater(
        core.openAppFromServer('s1'),
        throwsA(isA<StateError>()),
      );
    });
  });
}

class _FakeTenantSource implements TenantSource {
  _FakeTenantSource(this._map);
  final Map<String, TenantContext?> _map;

  @override
  Future<TenantContext?> resolve(String appCode) async => _map[appCode];
}
