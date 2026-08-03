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

    test(
        'IT-007: MCP Serving 1.0 — server bundle document is reconstructed + served',
        () async {
      // MCP Serving 1.0 — the server exposes the bundle document
      // alongside ui://app; the client reconstructs the McpBundle and serves
      // it in-process at the well-known URI (equivalence with a local bundle).
      final doc = <String, dynamic>{
        'schemaVersion': '1.0.0',
        'manifest': {'id': 'srv.bundle', 'name': 'Served', 'version': '1.0.0'},
        'settings': {
          'groups': [
            {'key': 'general', 'label': 'General', 'fields': <dynamic>[]},
          ],
        },
      };
      server.withResources([
        Resource(
          uri: 'ui://app',
          name: 'App',
          description: '',
          mimeType: 'application/json',
        ),
        Resource(
          uri: 'bundle://manifest.json',
          name: 'Bundle',
          description: '',
          mimeType: 'application/json',
        ),
      ]);
      server.withResourceContent('ui://app', minimalAppDefinition(id: 's1-app'));
      server.withResourceContent('bundle://manifest.json', doc);

      final session = await core.openAppFromServer('s1');
      expect(session.source, AppSource.server);

      // The reconstructed bundle is now served in-process at the well-known
      // URI, and reconstructs to the same manifest.
      expect(core.servedResources, contains('bundle://manifest.json'));
      final served = await core.readServedResource('bundle://manifest.json')
          as Map<String, dynamic>;
      expect((served['manifest'] as Map)['id'], 'srv.bundle');
    });

    test(
        'IT-007a: MCP Serving 1.0 — a served bundle\'s `bundle://` assets resolve',
        () async {
      // Equivalence (mcp_serving §Rules 2): the local path resolves
      // `bundle://` against the bundle\'s own assets before the runtime sees
      // the definition, so the served path must too. Without it the same
      // document renders locally and shows nothing over a connection —
      // mcp_ui_dsl §6.12.7 forbids the placement differing by arrival path.
      const pixel =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final doc = <String, dynamic>{
        'schemaVersion': '1.0.0',
        'manifest': {'id': 'srv.assets', 'name': 'Served', 'version': '1.0.0'},
        'assets': {
          'assets': [
            {
              'path': 'images/logo.png',
              'mimeType': 'image/png',
              'encoding': 'base64',
              'content': pixel,
            },
          ],
        },
      };
      // The reference sits in the application definition itself, which is the
      // document the runtime receives directly — the page loader carries the
      // same transform and is covered by the loader's own unit test.
      final app = <String, dynamic>{
        'type': 'application',
        'title': 'Served',
        'routes': {'/': 'ui://pages/home'},
        'splash': {'image': 'bundle://images/logo.png'},
      };
      final page = <String, dynamic>{
        'type': 'page',
        'content': {'type': 'text', 'content': 'home'},
      };
      server.withResources([
        Resource(
          uri: 'ui://app',
          name: 'App',
          description: '',
          mimeType: 'application/json',
        ),
        Resource(
          uri: 'bundle://manifest.json',
          name: 'Bundle',
          description: '',
          mimeType: 'application/json',
        ),
      ]);
      server.withResourceContent('ui://app', app);
      server.withResourceContent('ui://pages/home', page);
      server.withResourceContent('bundle://manifest.json', doc);

      final session = await core.openAppFromServer('s1');
      final runtime = core.runtimeManagerForInternals
          .getOrCreateRuntime(session.handle);
      final definition = runtime.getUIDefinition()!;
      final src = ((definition['splash'] as Map)['image'] as String);

      expect(src.startsWith('data:image/png;base64,'), isTrue,
          reason: 'the served bundle\'s asset must be resolved before the '
              'runtime sees it, not passed through as `bundle://` — got: $src');
      expect(src, contains(pixel));
    });

    test('IT-008: MCP Serving 1.0 — server without a bundle document is unaffected',
        () async {
      // The default setUp server serves only ui://app (an existing server).
      final session = await core.openAppFromServer('s1');
      expect(session.source, AppSource.server);
      expect(core.servedResources, isNot(contains('bundle://manifest.json')));
    });

    test('IT-003: tool dispatch returns parsed JSON response (fold is runtime responsibility)',
        () async {
      await core.openAppFromServer('s1');
      final result = await core.toolDispatcherForInternals.call(
        client: server.client,
        tool: 'incr',
        params: const {},
      );
      expect(result, equals({'count': 7}));
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
