import 'dart:async';

import 'package:appplayer_core/src/connection/connection_manager.dart';
import 'package:appplayer_core/src/connection/connection_state.dart';
import 'package:appplayer_core/src/model/server_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState;
import 'package:mocktail/mocktail.dart';

import 'package:appplayer_core/src/connection/shared_client.dart';

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
      // Cleared AND closed. Only clearing the reference left the socket open
      // for the life of the process, and the reconnect below could not close it
      // because by then there was no client to close.
      verify(() => client.disconnect()).called(1);

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
      // The keepalive ping throws with no reply behind it → link is dead.
      when(() => client.ping())
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
      verify(() => client.disconnect()).called(1);
    });

    test('TC-CONN-016: every keepalive miss on a tcp:// node closes the socket '
        'it gives up on, so reconnect cycles do not pile up open sockets',
        () async {
      // The leak this guards against was measured on a real ESP32 node: each
      // miss dropped the reference without closing it, the board's socket table
      // filled, it began resetting new connections, and every reset was another
      // miss. Three cycles here must close three clients, not zero.
      final clients = <MockClient>[];
      final m = ConnectionManager(connector: (_) async {
        final c = MockClient();
        when(() => c.disconnect()).thenReturn(null);
        when(() => c.onDisconnect)
            .thenAnswer((_) => const Stream<DisconnectReason>.empty());
        when(() => c.ping()).thenThrow(StateError('board reset'));
        clients.add(c);
        return c;
      });
      final node = ServerConfig(
        id: 'esp32.node',
        name: 'ESP32 MCP Node',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'tcp://mcp-esp32.local:6270'},
      );

      await m.connect(node);
      for (var i = 0; i < 3; i++) {
        await m.keepAliveSweep();
        expect(m.getConnection('esp32.node')!.state, ConnectionState.error);
        await m.reconnect('esp32.node');
      }

      expect(clients, hasLength(4));
      for (final c in clients.take(3)) {
        verify(() => c.disconnect()).called(1);
      }
    });

    test('TC-CONN-018: a keepalive probe that fails after its client was '
        'replaced does not drop the replacement', () async {
      // Measured on an ESP32 node: a slow probe outlived its client, the link
      // was re-dialled meanwhile, and the stale probe then tore down the fresh,
      // healthy connection — which started the whole cycle again.
      final probe = Completer<void>();
      final drops = StreamController<DisconnectReason>.broadcast();
      addTearDown(drops.close);
      final first = MockClient();
      when(() => first.disconnect()).thenReturn(null);
      when(() => first.onDisconnect).thenAnswer((_) => drops.stream);
      when(() => first.ping()).thenAnswer((_) => probe.future);
      final second = MockClient();
      when(() => second.disconnect()).thenReturn(null);
      when(() => second.onDisconnect)
          .thenAnswer((_) => const Stream<DisconnectReason>.empty());
      when(() => second.ping()).thenAnswer((_) async {});

      var calls = 0;
      final m = ConnectionManager(
          connector: (_) async => ++calls == 1 ? first : second);
      final node = ServerConfig(
        id: 'esp32.node',
        name: 'ESP32 MCP Node',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'tcp://mcp-esp32.local:6270'},
      );
      await m.connect(node);

      final sweep = m.keepAliveSweep(timeout: const Duration(seconds: 5));
      // The first link dies and is replaced while its probe is still pending.
      drops.add(DisconnectReason.transportClosed);
      await Future<void>.microtask(() {});
      await m.reconnect('esp32.node');
      expect((m.getConnection('esp32.node')!.client! as SharedClient).inner,
          same(second));

      probe.completeError(StateError('probe outlived its client'));
      await sweep;

      expect(m.getConnection('esp32.node')!.state, ConnectionState.connected);
      expect((m.getConnection('esp32.node')!.client! as SharedClient).inner,
          same(second));
      verifyNever(() => second.disconnect());
    });

    test('TC-CONN-019: a sweep that starts while one is still running does not '
        'probe again', () async {
      final probe = Completer<void>();
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.ping()).thenAnswer((_) => probe.future);
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(ServerConfig(
        id: 'tcp1',
        name: 'board',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'tcp://10.0.0.5:6270'},
      ));

      final a = m.keepAliveSweep(timeout: const Duration(seconds: 5));
      final b = m.keepAliveSweep(timeout: const Duration(seconds: 5));
      probe.complete();
      await Future.wait([a, b]);

      verify(() => client.ping()).called(1);
      expect(m.getConnection('tcp1')!.state, ConnectionState.connected);
    });

    // 23 §6.1.2 — anything the device sent is proof of life.
    ServerConfig board() => ServerConfig(
          id: 'tcp1',
          name: 'board',
          description: '',
          transportType: TransportType.streamableHttp,
          transportConfig: const {'baseUrl': 'tcp://10.0.0.5:6270'},
        );

    /// The handler the shared layer put on the inner client for resource
    /// updates — calling it is the device streaming an update.
    void Function() streamOf(MockClient inner) {
      final handler = verify(() => inner.onNotification(
              'notifications/resources/updated', captureAny()))
          .captured
          .last as Function(Map<String, dynamic>);
      return () => handler({'uri': 'sensor://uptime'});
    }

    test('TC-CONN-030: a link that is streaming is not probed', () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.ping()).thenAnswer((_) => Completer<void>().future);
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(board());
      final stream = streamOf(client);

      for (var i = 0; i < 6; i++) {
        stream(); // the device pushes an update
        await m.keepAliveSweep(timeout: const Duration(seconds: 4));
      }
      verifyNever(() => client.ping());
      expect(m.getConnection('tcp1')!.state, ConnectionState.connected);
    });

    test('TC-CONN-031: a late probe on a link that is still sending is not a '
        'miss — never dropped however many times it is late', () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      late void Function() stream;
      when(() => client.ping()).thenAnswer((_) {
        // The probe waits; meanwhile the device streams an update.
        Timer(const Duration(milliseconds: 5), () => stream());
        return Completer<void>().future;
      });
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(board());
      stream = streamOf(client);
      const t = Duration(milliseconds: 20);

      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await m.keepAliveSweep(timeout: t);
      }
      verify(() => client.ping()).called(6);
      verifyNever(() => client.disconnect());
      expect(m.getConnection('tcp1')!.state, ConnectionState.connected);
    });

    test('TC-CONN-032: a silent link is still dropped once the silence runs out',
        () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.ping()).thenAnswer((_) => Completer<void>().future);
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(board());
      const t = Duration(milliseconds: 20);
      const silence = Duration(milliseconds: 50);
      await m.keepAliveSweep(timeout: t, dropAfterSilence: silence);
      expect(m.getConnection('tcp1')!.state, ConnectionState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await m.keepAliveSweep(timeout: t, dropAfterSilence: silence);
      expect(m.getConnection('tcp1')!.state, ConnectionState.error);
    });

    test('TC-CONN-033: the wait follows the device — a slow but steady device '
        'is not judged by the floor', () async {
      var call = 0;
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.ping()).thenAnswer((_) async {
        call++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(board());
      const t = Duration(milliseconds: 20);
      for (var i = 0; i < 8; i++) {
        await m.keepAliveSweep(timeout: t);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      expect(call, 8);
      expect(m.getConnection('tcp1')!.state, ConnectionState.connected);
    });

    test('TC-CONN-034: every connection is shared; a board has a fixed '
        'surface and one request at a time, a borrowed device a fixed surface, '
        'a general server neither (23 §6.1)', () async {
      Future<ConnectionSharing> sharingOf(ServerConfig server) async {
        final client = mockClient();
        when(() => client.disconnect()).thenReturn(null);
        final m = ConnectionManager(connector: (_) async => client);
        await m.connect(server);
        final held = m.getConnection(server.id)!.client;
        expect(held, isA<SharedClient>());
        return (held! as SharedClient).sharing;
      }

      final boardS = await sharingOf(board());
      expect(boardS.surfaceFixed, isTrue);
      expect(boardS.maxInFlight, 1);

      final borrowed = await sharingOf(ServerConfig(
        id: 'peer.d.app',
        name: 'borrowed',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'peer://d/app'},
      ));
      expect(borrowed.surfaceFixed, isTrue);
      expect(borrowed.maxInFlight, isNull);

      final general = await sharingOf(_server());
      expect(general.surfaceFixed, isFalse);
      expect(general.maxInFlight, isNull);
    });

    test('TC-CONN-035: letting go is counted — the connection closes only '
        'when its last holder releases (23 §6.1.4)', () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(board());
      m.retain('tcp1', 'app');
      m.retain('tcp1', 'lend:phone');
      m.retain('tcp1', 'lend:phone'); // idempotent per holder

      await m.release('tcp1', 'app'); // this host's screen closes
      expect(m.getConnection('tcp1')!.state, ConnectionState.connected,
          reason: 'a lent session still uses it');
      verifyNever(() => client.disconnect());
      expect(m.isHeld('tcp1'), isTrue);

      await m.release('tcp1', 'lend:phone');
      expect(m.hasConnection('tcp1'), isFalse);
      verify(() => client.disconnect()).called(1);
    });

    test('TC-CONN-037: a reconnect replaces the connection; its holders stay',
        () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(board());
      m.retain('tcp1', 'lend:phone');
      await m.reconnect('tcp1');
      expect(m.isHeld('tcp1'), isTrue);
    });

    test('TC-CONN-036: taking the device away closes it whoever holds it',
        () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(board());
      m.retain('tcp1', 'lend:phone');
      await m.disconnect('tcp1');
      expect(m.hasConnection('tcp1'), isFalse);
      expect(m.isHeld('tcp1'), isFalse);
    });

    test('TC-CONN-020: missed probes keep the link while silence is shorter '
        'than the limit — however many there are', () async {
      // A board behind a lossy radio answers late while lwIP retransmits
      // (1.5 s, 3 s, 6 s …). Counting four misses against a wait that had
      // shrunk to 4.2 s dropped it; TCP would have delivered (2026-09-21).
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.ping())
          .thenAnswer((_) => Completer<void>().future); // never answers
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(ServerConfig(
        id: 'tcp1',
        name: 'board',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'tcp://10.0.0.5:6270'},
      ));
      const t = Duration(milliseconds: 10);
      const silence = Duration(milliseconds: 150);

      for (var i = 1; i <= 6; i++) {
        await m.keepAliveSweep(timeout: t, dropAfterSilence: silence);
        expect(m.getConnection('tcp1')!.state, ConnectionState.connected,
            reason: 'miss $i inside the silence limit');
      }
      verifyNever(() => client.disconnect());

      await Future<void>.delayed(silence);
      await m.keepAliveSweep(timeout: t, dropAfterSilence: silence);
      expect(m.getConnection('tcp1')!.state, ConnectionState.error,
          reason: 'nothing at all for the whole limit is a dead link');
    });

    test('TC-CONN-021: an answer between two timeouts starts the silence again',
        () async {
      var call = 0;
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.ping()).thenAnswer((_) {
        call++;
        return call == 2
            ? Future<void>.value()
            : Completer<void>().future;
      });
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(ServerConfig(
        id: 'tcp1',
        name: 'board',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'tcp://10.0.0.5:6270'},
      ));
      const t = Duration(milliseconds: 20);
      const silence = Duration(milliseconds: 90);

      await m.keepAliveSweep(timeout: t, dropAfterSilence: silence); // miss
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await m.keepAliveSweep(timeout: t, dropAfterSilence: silence); // answer
      await Future<void>.delayed(const Duration(milliseconds: 40));
      // Past the limit counted from the connect, inside it counted from the
      // answer: the answer is what the silence is measured from.
      await m.keepAliveSweep(timeout: t, dropAfterSilence: silence); // miss

      expect(m.getConnection('tcp1')!.state, ConnectionState.connected);
    });

    test('TC-CONN-023: an answer that arrives after its probe timed out still '
        'proves the link alive', () async {
      // Measured: missed (4.0 s) → answer arrived at 7.9 s → missed (4.0 s) →
      // answer at 4.4 s → dropped. Both "misses" were answered; the board was
      // slow, not gone.
      final answers = <Completer<void>>[];
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.ping()).thenAnswer((_) {
        final c = Completer<void>();
        answers.add(c);
        return c.future;
      });
      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(ServerConfig(
        id: 'tcp1',
        name: 'board',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'tcp://10.0.0.5:6270'},
      ));
      const t = Duration(milliseconds: 20);
      const silence = Duration(milliseconds: 60);

      await m.keepAliveSweep(timeout: t, dropAfterSilence: silence); // miss
      await Future<void>.delayed(const Duration(milliseconds: 40));
      answers.last.complete(); // …but it answers, late
      await Future<void>.delayed(Duration.zero);
      await m.keepAliveSweep(timeout: t, dropAfterSilence: silence); // miss again

      expect(m.getConnection('tcp1')!.state, ConnectionState.connected);
    });

    test('TC-CONN-022: a device that answers ping with a JSON-RPC error is alive; '
        'a failure with no reply behind it is not', () async {
      // The ESP32 node never implemented ping and replies "Method not found"
      // in 0.2 s — that is an answer. A transport failure carries no code.
      Future<ConnectionState> after(Object error) async {
        final client = mockClient();
        when(() => client.disconnect()).thenReturn(null);
        when(() => client.ping()).thenAnswer((_) => Future<void>.error(error));
        final m = ConnectionManager(connector: (_) async => client);
        await m.connect(ServerConfig(
          id: 'tcp1',
          name: 'board',
          description: '',
          transportType: TransportType.streamableHttp,
          transportConfig: const {'baseUrl': 'tcp://10.0.0.5:6270'},
        ));
        await m.keepAliveSweep();
        return m.getConnection('tcp1')!.state;
      }

      expect(await after(const McpError('Method not found', code: -32601)),
          ConnectionState.connected);
      expect(await after(const McpError('Transport error: socket closed')),
          ConnectionState.error);
    });

    test('TC-CONN-017: a dead client that throws while closing still leaves '
        'the entry marked for reconnect', () async {
      final client = mockClient();
      when(() => client.disconnect()).thenThrow(StateError('already gone'));
      when(() => client.ping()).thenThrow(StateError('transport gone'));

      final m = ConnectionManager(connector: (_) async => client);
      await m.connect(ServerConfig(
        id: 'tcp1',
        name: 'board',
        description: '',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'tcp://10.0.0.5:6270'},
      ));

      await m.keepAliveSweep();

      // Tidying up is not the point of the handler: the health monitor still
      // has to see an error entry, or the node is never reconnected.
      expect(m.getConnection('tcp1')!.state, ConnectionState.error);
      expect(m.getConnection('tcp1')!.client, isNull);
    });

    test('TC-CONN-015: keepAliveSweep skips plain http servers (no idle-drop, '
        'no noise poll)', () async {
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      when(() => client.ping()).thenAnswer((_) async {});

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
      verifyNever(() => client.ping());
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
