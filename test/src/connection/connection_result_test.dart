import 'package:appplayer_core/src/connection/connection_info.dart';
import 'package:appplayer_core/src/connection/connection_result.dart';
import 'package:appplayer_core/src/connection/connection_state.dart';
import 'package:appplayer_core/src/model/server_config.dart';
import 'package:flutter_test/flutter_test.dart';

ConnectionInfo _info() => ConnectionInfo(
      serverId: 'id',
      serverName: 'n',
      serverConfig: ServerConfig(
        id: 'id',
        name: 'n',
        description: 'd',
        transportType: TransportType.stdio,
        transportConfig: const {'command': 'dart'},
      ),
      state: ConnectionState.connecting,
    );

void main() {
  group('ConnectionResult (MOD-MODEL-002)', () {
    test('TC-CONNMODEL-003: success', () {
      final info = _info();
      final r = ConnectionResult.success(info);
      expect(r.success, isTrue);
      expect(r.connection, same(info));
      expect(r.error, isNull);
    });

    test('TC-CONNMODEL-004: failure', () {
      final r = ConnectionResult.failure('oops');
      expect(r.success, isFalse);
      expect(r.connection, isNull);
      expect(r.error, 'oops');
    });
  });

  group('ConnectionInfo', () {
    test('TC-CONNMODEL-001: isHealthy requires connected + client', () {
      final info = _info();
      expect(info.isHealthy, isFalse);

      info.state = ConnectionState.connected;
      expect(info.isHealthy, isFalse); // client still null

      info.state = ConnectionState.error;
      expect(info.isHealthy, isFalse);
    });

    test('TC-CONNMODEL-002: connectionDuration from connectedAt', () {
      final info = _info();
      expect(info.connectionDuration, isNull);
      info.connectedAt = DateTime.now().subtract(const Duration(seconds: 5));
      final d = info.connectionDuration;
      expect(d, isNotNull);
      expect(d!.inSeconds >= 4, isTrue);
    });
  });
}
