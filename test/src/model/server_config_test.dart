import 'package:appplayer_core/src/model/server_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerConfig (MOD-MODEL-001)', () {
    test('TC-SVCFG-001: defaults', () {
      final c = ServerConfig(
        name: 'n',
        description: 'd',
        transportType: TransportType.stdio,
        transportConfig: const {'command': 'dart'},
      );
      expect(c.id, isNotEmpty);
      expect(c.createdAt.isBefore(DateTime.now().add(const Duration(seconds: 1))),
          isTrue);
      expect(c.isFavorite, isFalse);
      expect(c.lastConnectedAt, isNull);
      expect(c.metadata, isNull);
    });

    test('TC-SVCFG-002: explicit id/createdAt', () {
      final t = DateTime(2026, 1, 1);
      final c = ServerConfig(
        id: 'fixed',
        name: 'n',
        description: 'd',
        transportType: TransportType.sse,
        transportConfig: const {'serverUrl': 'x'},
        createdAt: t,
      );
      expect(c.id, 'fixed');
      expect(c.createdAt, t);
    });

    test('TC-SVCFG-003: toJson/fromJson roundtrip', () {
      final c = ServerConfig(
        id: 'id1',
        name: 'n',
        description: 'd',
        transportType: TransportType.streamableHttp,
        transportConfig: const {'baseUrl': 'http://x'},
        createdAt: DateTime.utc(2026, 4, 15),
        lastConnectedAt: DateTime.utc(2026, 4, 15, 12),
        isFavorite: true,
        metadata: const {'v': 1},
      );
      final roundTrip = ServerConfig.fromJson(c.toJson());
      expect(roundTrip.id, c.id);
      expect(roundTrip.name, c.name);
      expect(roundTrip.description, c.description);
      expect(roundTrip.transportType, c.transportType);
      expect(roundTrip.transportConfig, c.transportConfig);
      expect(roundTrip.createdAt, c.createdAt);
      expect(roundTrip.lastConnectedAt, c.lastConnectedAt);
      expect(roundTrip.isFavorite, c.isFavorite);
      expect(roundTrip.metadata, c.metadata);
    });

    test('TC-SVCFG-004: legacy transportType migration', () {
      Map<String, dynamic> base() => {
            'id': 'i',
            'name': 'n',
            'description': 'd',
            'transportConfig': const <String, dynamic>{},
            'createdAt': DateTime.utc(2026).toIso8601String(),
          };

      expect(
        ServerConfig.fromJson({...base(), 'transportType': 'tcp'}).transportType,
        TransportType.sse,
      );
      expect(
        ServerConfig.fromJson({...base(), 'transportType': 'websocket'})
            .transportType,
        TransportType.sse,
      );
      expect(
        ServerConfig.fromJson({...base(), 'transportType': 'http'}).transportType,
        TransportType.streamableHttp,
      );
      expect(
        ServerConfig.fromJson({...base(), 'transportType': 'unknown'})
            .transportType,
        TransportType.stdio,
      );
    });

    test('TC-SVCFG-005: copyWith partial update preserves rest', () {
      final c = ServerConfig(
        id: 'id1',
        name: 'n',
        description: 'd',
        transportType: TransportType.stdio,
        transportConfig: const {'command': 'dart'},
      );
      final c2 = c.copyWith(isFavorite: true);
      expect(c2.id, c.id);
      expect(c2.name, c.name);
      expect(c2.isFavorite, true);
      expect(c.isFavorite, false);
    });

    test('TC-SVCFG-006: TransportType.displayName', () {
      expect(TransportType.stdio.displayName, 'STDIO (Process)');
      expect(TransportType.sse.displayName, 'SSE (Server-Sent Events)');
      expect(TransportType.streamableHttp.displayName, 'HTTP (Streamable)');
    });
  });
}
