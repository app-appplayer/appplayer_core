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
      final client = MockClient();
      when(() => client.disconnect()).thenReturn(null);

      final m = ConnectionManager(connector: (_) async => client);
      final result = await m.connect(_server());

      expect(result.success, isTrue);
      expect(m.hasConnection('s1'), isTrue);
      expect(m.getConnection('s1')!.state, ConnectionState.connected);
    });

    test('TC-CONN-002: connect reuses existing connected', () async {
      var calls = 0;
      final client = MockClient();
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
      final client = MockClient();
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
      final client = MockClient();
      when(() => client.disconnect()).thenReturn(null);
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(_server());
      await m.disconnect('s1');
      expect(m.hasConnection('s1'), isFalse);
      verify(() => client.disconnect()).called(1);
    });

    test('TC-CONN-007: disconnect unknown id is a no-op', () async {
      final m = ConnectionManager(connector: (_) async => MockClient());
      await m.disconnect('nope');
      expect(m.connections.isEmpty, isTrue);
    });

    test('TC-CONN-008: disconnectAll clears registry', () async {
      final m = ConnectionManager(connector: (_) async {
        final c = MockClient();
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
        final c = MockClient();
        when(() => c.disconnect()).thenReturn(null);
        return c;
      });
      await m.connect(_server());
      final r = await m.reconnect('s1');
      expect(r.success, isTrue);
      expect(calls, 2);
    });

    test('TC-CONN-010: reconnect unknown id failure', () async {
      final m = ConnectionManager(connector: (_) async => MockClient());
      final r = await m.reconnect('nope');
      expect(r.success, isFalse);
      expect(r.error, 'No connection found for server');
    });

    test('TC-CONN-012: state transitions notify listeners', () async {
      final events = <ConnectionState>[];
      final m = ConnectionManager(connector: (_) async {
        final c = MockClient();
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
}
