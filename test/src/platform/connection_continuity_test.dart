import 'package:appplayer_core/src/connection/connection_continuity.dart';
import 'package:appplayer_core/src/connection/connection_manager.dart';
import 'package:appplayer_core/src/connection/connection_state.dart';
import 'package:appplayer_core/src/model/server_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState;
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

ServerConfig _server(String id) => ServerConfig(
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

  /// Connector that hands out a fresh MockClient per call and counts calls, so
  /// reconnect behaviour is observable.
  ({ConnectionManager manager, int Function() connects}) _managerWith() {
    var connects = 0;
    final manager = ConnectionManager(connector: (_) async {
      connects++;
      final client = mockClient();
      when(() => client.disconnect()).thenReturn(null);
      return client;
    });
    return (manager: manager, connects: () => connects);
  }

  group('ConnectionContinuity (FR-CONT)', () {
    test('pauseAll snapshots live servers and disconnects them', () async {
      final m = _managerWith();
      await m.manager.connect(_server('a'));
      await m.manager.connect(_server('b'));
      expect(m.manager.connections.length, 2);

      final continuity = ConnectionContinuity(connections: m.manager);
      await continuity.pauseAll();

      expect(continuity.isPaused, isTrue);
      expect(continuity.pausedCursors.keys.toSet(), {'a', 'b'});
      expect(m.manager.connections, isEmpty,
          reason: 'sockets released while backgrounded');
    });

    test('resumeAll reconnects every paused server', () async {
      final m = _managerWith();
      await m.manager.connect(_server('a'));
      await m.manager.connect(_server('b'));
      final baseline = m.connects();

      final continuity = ConnectionContinuity(connections: m.manager);
      await continuity.pauseAll();
      await continuity.resumeAll();

      expect(continuity.isPaused, isFalse);
      expect(m.manager.connections.keys.toSet(), {'a', 'b'});
      expect(m.connects(), baseline + 2, reason: 'each server reconnected');
    });

    test('pauseAll with no live connections is a no-op', () async {
      final m = _managerWith();
      final continuity = ConnectionContinuity(connections: m.manager);
      await continuity.pauseAll();
      expect(continuity.isPaused, isFalse);
    });

    test('resumeAll without a prior pause sweeps stale connections', () async {
      final m = _managerWith();
      await m.manager.connect(_server('a'));
      // Force the connection into error state so the sweep reconnects it.
      m.manager.getConnection('a')!.state = ConnectionState.error;
      final baseline = m.connects();

      final continuity = ConnectionContinuity(connections: m.manager);
      await continuity.resumeAll();

      expect(m.connects(), baseline + 1, reason: 'stale connection reconnected');
      expect(m.manager.getConnection('a')!.state, ConnectionState.connected);
    });

    test('sweepStale reconnects only error-state connections', () async {
      final m = _managerWith();
      await m.manager.connect(_server('a'));
      await m.manager.connect(_server('b'));
      m.manager.getConnection('a')!.state = ConnectionState.error;
      final baseline = m.connects();

      final continuity = ConnectionContinuity(connections: m.manager);
      await continuity.sweepStale();

      expect(m.connects(), baseline + 1,
          reason: 'only the stale server reconnected');
    });
  });
}
