import 'package:appplayer_core/src/connection/connection_health_monitor.dart';
import 'package:appplayer_core/src/connection/connection_manager.dart';
import 'package:appplayer_core/src/connection/connection_state.dart';
import 'package:appplayer_core/src/model/server_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState;
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

ServerConfig _server() => ServerConfig(
      id: 's1',
      name: 'n',
      description: 'd',
      transportType: TransportType.stdio,
      transportConfig: const {'command': 'dart'},
    );

void main() {
  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
  });

  group('ConnectionHealthMonitor (MOD-CONN-003)', () {
    test('TC-HEALTH-003+004+005: reconnects up to max, resets on success',
        () async {
      var attempts = 0;
      final m = ConnectionManager(connector: (_) async {
        attempts++;
        if (attempts <= 3) {
          throw StateError('flaky');
        }
        final c = MockClient();
        when(() => c.disconnect()).thenReturn(null);
        return c;
      });
      await m.connect(_server());
      expect(m.getConnection('s1')!.state, ConnectionState.error);

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 20),
          maxReconnectAttempts: 5,
          reconnectDelay: Duration(milliseconds: 5),
        ),
      );
      monitor.startMonitoring();

      // Wait for reconnect attempts to run.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      monitor.stopMonitoring();

      expect(attempts >= 4, isTrue,
          reason: 'Monitor should retry until success');
      expect(m.getConnection('s1')!.state, ConnectionState.connected);
      // Counter resets on successful reconnect.
      expect(monitor.getReconnectAttempts('s1'), 0);
    });

    test('TC-HEALTH-004: stops after max attempts', () async {
      final m = ConnectionManager(
          connector: (_) async => throw StateError('always-fail'));
      await m.connect(_server());

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 10),
          maxReconnectAttempts: 2,
          reconnectDelay: Duration(milliseconds: 2),
        ),
      );
      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      monitor.stopMonitoring();

      expect(monitor.getReconnectAttempts('s1'), 2);
    });

    test('TC-HEALTH-008: resetReconnectAttempts allows retries again',
        () async {
      final m = ConnectionManager(
          connector: (_) async => throw StateError('fail'));
      await m.connect(_server());

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 10),
          maxReconnectAttempts: 1,
          reconnectDelay: Duration(milliseconds: 2),
        ),
      );
      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(monitor.getReconnectAttempts('s1'), 1);

      monitor.resetReconnectAttempts('s1');
      expect(monitor.getReconnectAttempts('s1'), 0);

      monitor.stopMonitoring();
    });

    test('TC-HEALTH-007: stopMonitoring halts checks', () async {
      final m = ConnectionManager(
          connector: (_) async => throw StateError('fail'));
      await m.connect(_server());

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 10),
          reconnectDelay: Duration(milliseconds: 2),
        ),
      );
      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      monitor.stopMonitoring();
      final snap = monitor.getReconnectAttempts('s1');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(monitor.getReconnectAttempts('s1'), snap,
          reason: 'No further attempts after stop');
    });
  });
}
