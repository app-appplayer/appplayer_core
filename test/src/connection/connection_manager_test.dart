import 'dart:async';

import 'package:appplayer_core/src/connection/connection_manager.dart';
import 'package:appplayer_core/src/connection/connection_state.dart';
import 'package:appplayer_core/src/model/server_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState;
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

ServerConfig _server([String id = 's1']) => ServerConfig(
      id: id,
      name: 'name-$id',
      description: 'd',
      transportType: TransportType.stdio,
      transportConfig: const {'command': 'dart'},
    );

void main() {
  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
  });

  group('ConnectionManager (MOD-CONN-001)', () {
    test('TC-CONN-001: connect creates new entry', () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);

      final m = ConnectionManager(connector: (_) async => client);
      final result = await m.connect(_server());

      expect(result.success, isTrue);
      expect(m.hasConnection('s1'), isTrue);
      expect(m.getConnection('s1')!.state, ConnectionState.connected);
    });

    test('TC-CONN-013: a transport that drops on its own is marked error with '
        'its dead client cleared (badge dark, health monitor can reconnect), '
        'and reconnect dials fresh', () async {
      // A client whose onDisconnect we control — simulate a BLE supervision
      // timeout after a successful connect.
      final drops = StreamController<DisconnectReason>.broadcast();
      addTearDown(drops.close);
      var connectCalls = 0;
      final client = MockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.onDisconnect).thenAnswer((_) => drops.stream);

      final m = ConnectionManager(connector: (_) async {
        connectCalls++;
        return client;
      });

      final ok = await m.connect(_server());
      expect(ok.success, isTrue);
      expect(m.getConnection('s1')!.state, ConnectionState.connected);

      // Transport drops without an explicit disconnect() call.
      drops.add(DisconnectReason.transportClosed);
      await Future<void>.microtask(() {});

      // Entry kept but marked error + dead client cleared: isServerConnected
      // (state==connected) reads false so the badge clears and the session's
      // client getter goes null; the entry stays so the health monitor can act.
      final info = m.getConnection('s1')!;
      expect(info.state, ConnectionState.error);
      expect(info.client, isNull);

      // reconnect() (what the health monitor calls) dials fresh under the same
      // id — the new client replaces the corpse and a session picks it up.
      final re = await m.reconnect('s1');
      expect(re.success, isTrue);
      expect(connectCalls, 2);
      expect(m.getConnection('s1')!.state, ConnectionState.connected);
    });

    test('TC-CONN-014: keepAliveSweep pings a transient ble:// link and marks '
        'it error when the probe fails (health monitor then reconnects)',
        () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      // First listResources (keepalive probe) throws → link is dead.
      when(() => client.listResources())
          .thenThrow(StateError('transport gone'));

      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(ServerConfig(
        id: 'ble1',
        name: 'board',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'ble://AA:BB'},
      ));
      expect(m.getConnection('ble1')!.state, ConnectionState.connected);

      await m.keepAliveSweep();

      // Dead probe → marked error + client cleared, ready for reconnect.
      expect(m.getConnection('ble1')!.state, ConnectionState.error);
      expect(m.getConnection('ble1')!.client, isNull);
    });

    test('TC-CONN-015: keepAliveSweep skips plain http servers (no idle-drop, '
        'no noise poll)', () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.listResources()).thenAnswer((_) async => const []);

      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(ServerConfig(
        id: 'http1',
        name: 'web',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'https://example.com/mcp'},
      ));

      await m.keepAliveSweep();

      expect(m.getConnection('http1')!.state, ConnectionState.connected);
      verifyNever(() => client.listResources());
    });

    test('TC-CONN-002: connect reuses existing connected', () async {
      var calls = 0;
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);

      final m = ConnectionManager(connector: (_) async {
        calls++;
        return client;
      });
      await m.connect(_server());
      await m.connect(_server());
      expect(calls, 1);
    });

    test('TC-CONN-003: connect awaits in-flight attempt', () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);

      // Gate the first connect to simulate in-flight.
      final completer = Completer<Client>();
      var connectorCalls = 0;

      final m = ConnectionManager(
        connector: (_) {
          connectorCalls++;
          return completer.future;
        },
        waitCheckInterval: const Duration(milliseconds: 10),
      );

      final first = m.connect(_server());
      // second call while first is connecting
      final second = m.connect(_server());

      completer.complete(client);

      final r1 = await first;
      final r2 = await second;

      expect(r1.success, isTrue);
      expect(r2.success, isTrue);
      expect(connectorCalls, 1, reason: 'Only one handshake expected');
    });

    test('TC-CONN-004: connect failure sets error state', () async {
      final m = ConnectionManager(
          connector: (_) async => throw StateError('nope'));
      final result = await m.connect(_server());
      expect(result.success, isFalse);
      expect(result.error, contains('nope'));
      expect(m.getConnection('s1')!.state, ConnectionState.error);
    });

    // TC-CONN-005 (timeout) moved to connection_manager_timeout_test.dart
    // using FakeAsync for deterministic timing.

    test('TC-CONN-006: disconnect removes entry', () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(_server());
      await m.disconnect('s1');
      expect(m.hasConnection('s1'), isFalse);
      verify(() => client.disconnect()).called(1);
    });

    test('TC-CONN-007: disconnect unknown id is a no-op', () async {
      final m = ConnectionManager(connector: (_) async => mockClient());
      await m.disconnect('nope');
      expect(m.connections.isEmpty, isTrue);
    });

    test('TC-CONN-008: disconnectAll clears registry', () async {
      final m = ConnectionManager(connector: (_) async {
        final c = mockClient();
        when(() => c.disconnect()).thenReturn(null);
        return c;
      });
      await m.connect(_server('a'));
      await m.connect(_server('b'));
      await m.disconnectAll();
      expect(m.connections.isEmpty, isTrue);
    });

    test('TC-CONN-009: reconnect calls disconnect then connect', () async {
      var calls = 0;
      final m = ConnectionManager(connector: (_) async {
        calls++;
        final c = mockClient();
        when(() => c.disconnect()).thenReturn(null);
        return c;
      });
      await m.connect(_server());
      final r = await m.reconnect('s1');
      expect(r.success, isTrue);
      expect(calls, 2);
    });

    test('TC-CONN-010: reconnect unknown id failure', () async {
      final m = ConnectionManager(connector: (_) async => mockClient());
      final r = await m.reconnect('nope');
      expect(r.success, isFalse);
      expect(r.error, 'No connection found for server');
    });

    test('TC-CONN-012: state transitions notify listeners', () async {
      final events = <ConnectionState>[];
      final m = ConnectionManager(connector: (_) async {
        final c = mockClient();
        when(() => c.disconnect()).thenReturn(null);
        return c;
      });
      m.addListener(() {
        final info = m.getConnection('s1');
        if (info != null) events.add(info.state);
      });
      await m.connect(_server());
      expect(events, contains(ConnectionState.connecting));
      expect(events, contains(ConnectionState.connected));
    });
  });

  group('ConnectionManager durable reconnect (token re-grant)', () {
    ServerConfig tokenServer(String token) => ServerConfig(
          id: 's1',
          name: 'srv',
          description: 'd',
          transportType: TransportType.streamableHttp,
          transportConfig: {'baseUrl': 'https://x', 'accessToken': token},
        );

    test('TC-CONN-REGRANT-001: a token-bearing server whose connect fails is '
        're-granted a fresh token and retried once → success', () async {
      var connectCalls = 0;
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      final m = ConnectionManager(connector: (_) async {
        connectCalls++;
        if (connectCalls == 1) {
          throw StateError('Failed to connect: 401 Authentication required');
        }
        return client;
      });
      var reGrantCalls = 0;
      m.tokenReGrant = (stale) async {
        reGrantCalls++;
        return stale.copyWith(transportConfig: {
          ...stale.transportConfig,
          'accessToken': 'fresh',
        });
      };

      final result = await m.connect(tokenServer('stale'));

      expect(result.success, isTrue);
      expect(connectCalls, 2, reason: 'stale attempt + fresh retry');
      expect(reGrantCalls, 1, reason: 're-grant invoked exactly once');
      expect(m.getConnection('s1')!.state, ConnectionState.connected);
    });

    test('TC-CONN-REGRANT-002: no hook wired → failure surfaces unchanged '
        '(prior behaviour, no retry)', () async {
      var connectCalls = 0;
      final m = ConnectionManager(connector: (_) async {
        connectCalls++;
        throw StateError('boom');
      });
      final result = await m.connect(tokenServer('stale'));
      expect(result.success, isFalse);
      expect(connectCalls, 1);
    });

    test('TC-CONN-REGRANT-003: no bearer token → hook never called '
        '(discovered board / no-auth server untouched)', () async {
      var reGrantCalls = 0;
      final m = ConnectionManager(connector: (_) async => throw StateError('x'))
        ..tokenReGrant = (stale) async {
          reGrantCalls++;
          return null;
        };
      final result = await m.connect(_server()); // stdio, no accessToken
      expect(result.success, isFalse);
      expect(reGrantCalls, 0);
    });

    test('TC-CONN-REGRANT-004: hook yields null (or unchanged token) → original '
        'failure, no retry loop', () async {
      var connectCalls = 0;
      final m = ConnectionManager(connector: (_) async {
        connectCalls++;
        throw StateError('boom');
      })..tokenReGrant = (stale) async => null;
      final result = await m.connect(tokenServer('stale'));
      expect(result.success, isFalse);
      expect(connectCalls, 1, reason: 'null re-grant → no fresh retry');
    });
  });
}
