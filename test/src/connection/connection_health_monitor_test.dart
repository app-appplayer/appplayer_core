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
        final c = mockClient();
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

    test('TC-HEALTH-010: default config never gives up while monitoring runs',
        () async {
      var attempts = 0;
      final m = ConnectionManager(connector: (_) async {
        attempts++;
        throw StateError('always-fail');
      });
      await m.connect(_server());
      attempts = 0;

      final monitor = ConnectionHealthMonitor(
        conn: m,
        // No maxReconnectAttempts — the default. The old default was 3, which
        // stranded a foreground app the moment the network went away for
        // longer than three tries (hotspot off, then back on minutes later).
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 10),
          reconnectDelay: Duration(milliseconds: 2),
          maxReconnectDelay: Duration(milliseconds: 4),
        ),
      );
      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      monitor.stopMonitoring();

      expect(attempts, greaterThan(5),
          reason: 'Retries must continue past any fixed attempt cap');
      expect(monitor.getReconnectAttempts('s1'), greaterThan(5));
    });

    test('TC-HEALTH-011: backoff doubles from the delay up to the ceiling',
        () async {
      final monitor = ConnectionHealthMonitor(
        conn: ConnectionManager(connector: (_) async => mockClient()),
        config: const HealthMonitorConfig(
          reconnectDelay: Duration(seconds: 1),
          maxReconnectDelay: Duration(seconds: 10),
        ),
      );

      expect(monitor.backoffFor(0), const Duration(seconds: 1));
      expect(monitor.backoffFor(1), const Duration(seconds: 2));
      expect(monitor.backoffFor(2), const Duration(seconds: 4));
      expect(monitor.backoffFor(3), const Duration(seconds: 8));
      // Ceiling, and it stays there however long the outage lasts.
      expect(monitor.backoffFor(4), const Duration(seconds: 10));
      expect(monitor.backoffFor(50), const Duration(seconds: 10));
    });

    test('TC-HEALTH-015: an engaged server does not back off', () async {
      final m = ConnectionManager(
          connector: (_) async => throw StateError('always-fail'));
      await m.connect(_server());

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 5),
          reconnectDelay: Duration(milliseconds: 10),
          maxReconnectDelay: Duration(seconds: 10),
        ),
      )..isEngaged = (_) => true;

      // Idle would be 10·20·40·80…ms; engaged stays at the first step however
      // long the outage lasts, so an app on screen recovers as fast on attempt
      // 20 as on attempt 1.
      expect(monitor.backoffFor(0, engaged: true),
          const Duration(milliseconds: 10));
      expect(monitor.backoffFor(20, engaged: true),
          const Duration(milliseconds: 10));
      expect(monitor.backoffFor(20), const Duration(seconds: 10));

      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      monitor.stopMonitoring();

      // With a growing backoff this window holds ~5 attempts; at a flat 10ms it
      // is an order of magnitude more.
      expect(monitor.getReconnectAttempts('s1'), greaterThan(10));
    });

    test('TC-HEALTH-016: an engaged server is not abandoned at an explicit cap',
        () async {
      final m = ConnectionManager(
          connector: (_) async => throw StateError('always-fail'));
      await m.connect(_server());

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 5),
          reconnectDelay: Duration(milliseconds: 5),
          maxReconnectAttempts: 2,
        ),
      )..isEngaged = (_) => true;

      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      monitor.stopMonitoring();

      expect(monitor.getReconnectAttempts('s1'), greaterThan(2),
          reason: 'A host cap must not strand the app the user has open');
    });

    test('TC-HEALTH-017: an engaged server retries on its own fixed pace',
        () async {
      var attempts = 0;
      final m = ConnectionManager(connector: (_) async {
        attempts++;
        throw StateError('always-fail');
      });
      await m.connect(_server());
      attempts = 0;

      final monitor = ConnectionHealthMonitor(
        conn: m,
        // The sweep is far too slow to drive retries here: anything beyond the
        // first attempt has to come from the retry chain re-arming itself, so
        // the interval the host asked for is the interval that happens.
        config: const HealthMonitorConfig(
          checkInterval: Duration(seconds: 10),
          reconnectDelay: Duration(milliseconds: 20),
        ),
      )..isEngaged = (_) => true;

      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      monitor.stopMonitoring();

      // ~10 at a true 20ms pace; sweep-driven it would be exactly 1.
      expect(attempts, greaterThan(5));
    });

    test('TC-HEALTH-020: a reachability hint cuts the wait short', () async {
      var attempts = 0;
      final m = ConnectionManager(connector: (_) async {
        attempts++;
        throw StateError('always-fail');
      });
      await m.connect(_server());
      attempts = 0;

      final monitor = ConnectionHealthMonitor(
        conn: m,
        // A long wait on purpose: without the hint nothing happens in this
        // test's lifetime, so any dial observed came from the hint.
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 5),
          reconnectDelay: Duration(seconds: 30),
        ),
      );
      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(attempts, 0, reason: 'Still waiting out the 30s interval');

      monitor.retryNow('s1');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      monitor.stopMonitoring();

      expect(attempts, 1, reason: 'The hint dials now, not in 30 seconds');
      expect(monitor.getReconnectAttempts('s1'), 1,
          reason: 'A hint restarts the pacing rather than counting against it');
    });

    test('TC-HEALTH-021: retryAllNow serves servers with no discovery axis',
        () async {
      // The cloud case: two remote servers, nothing local ever "sights" them,
      // and connectivity returning names none of them.
      var dials = 0;
      final m = ConnectionManager(connector: (t) async {
        dials++;
        throw StateError('always-fail');
      });
      for (final id in ['cloud-a', 'cloud-b']) {
        await m.connect(ServerConfig(
          id: id,
          name: id,
          description: 'd',
          transportType: TransportType.stdio,
          transportConfig: const {'command': 'dart'},
        ));
      }

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 5),
          reconnectDelay: Duration(seconds: 30),
        ),
      );
      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      dials = 0; // the initial failed connects are not what is being measured

      monitor.retryAllNow();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      monitor.stopMonitoring();

      // Both, not just whichever came first — a connectivity signal cannot
      // pick a server, so serving only one silently strands the rest.
      expect(dials, 2);
    });

    test('TC-HEALTH-019: a slow dial is never overlapped by the next retry',
        () async {
      var inFlight = 0;
      var maxInFlight = 0;
      var attempts = 0;
      final m = ConnectionManager(connector: (_) async {
        attempts++;
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        // A real dial is slow — a BLE connect runs seconds, far longer than the
        // 1s pace an engaged server retries on.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        inFlight--;
        throw StateError('always-fail');
      });
      await m.connect(_server());
      attempts = 0;
      maxInFlight = 0;

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 5),
          reconnectDelay: Duration(milliseconds: 10),
        ),
      )..isEngaged = (_) => true;

      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      monitor.stopMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(maxInFlight, 1,
          reason: 'The pace applies between dials, not on top of one');
      // ~3 in the window (10ms wait + 120ms dial), nowhere near the ~80 a
      // 5ms sweep would produce if it dialled independently.
      expect(attempts, lessThan(10));
    });

    test('TC-HEALTH-018: closing the app hands pacing back to the sweep',
        () async {
      var attempts = 0;
      var open = true;
      final m = ConnectionManager(connector: (_) async {
        attempts++;
        throw StateError('always-fail');
      });
      await m.connect(_server());
      attempts = 0;

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(seconds: 10),
          reconnectDelay: Duration(milliseconds: 20),
        ),
      )..isEngaged = (_) => open;

      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      open = false;
      final atClose = attempts;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      monitor.stopMonitoring();

      // The self-arming loop must stop; the slow sweep owns it again, and it
      // will not tick inside this window.
      expect(attempts, lessThanOrEqualTo(atClose + 1),
          reason: 'A closed app must not keep the fast loop alive');
    });

    test('TC-HEALTH-012: a pending backoff is not stacked by faster ticks',
        () async {
      var attempts = 0;
      final m = ConnectionManager(connector: (_) async {
        attempts++;
        throw StateError('always-fail');
      });
      await m.connect(_server());
      attempts = 0;

      final monitor = ConnectionHealthMonitor(
        conn: m,
        // Detection far faster than the retry pace — Pro's shape (2s sweep,
        // seconds-long backoff). Each sweep must see the reconnect already
        // scheduled and leave it alone, not dial again.
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 5),
          reconnectDelay: Duration(milliseconds: 200),
        ),
      );
      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      monitor.stopMonitoring();

      expect(attempts, 0, reason: 'Backoff has not elapsed yet');
      expect(monitor.getReconnectAttempts('s1'), 1,
          reason: '~16 sweeps must schedule one attempt, not sixteen');
    });

    test('TC-HEALTH-013: stopping stands down a reconnect already waiting',
        () async {
      var attempts = 0;
      final m = ConnectionManager(connector: (_) async {
        attempts++;
        throw StateError('always-fail');
      });
      await m.connect(_server());
      attempts = 0;

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 5),
          reconnectDelay: Duration(milliseconds: 100),
        ),
      );
      monitor.startMonitoring();
      // Stop mid-backoff: the scheduled reconnect is still in flight.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      monitor.stopMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(attempts, 0,
          reason: 'A backgrounded app must not dial after monitoring stopped');
    });

    test('TC-HEALTH-014: startMonitoring clears grown backoff', () async {
      final m = ConnectionManager(
          connector: (_) async => throw StateError('always-fail'));
      await m.connect(_server());

      final monitor = ConnectionHealthMonitor(
        conn: m,
        config: const HealthMonitorConfig(
          checkInterval: Duration(milliseconds: 10),
          reconnectDelay: Duration(milliseconds: 2),
          maxReconnectDelay: Duration(milliseconds: 4),
        ),
      );
      monitor.startMonitoring();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(monitor.getReconnectAttempts('s1'), greaterThan(1));

      // A foreground return is new information — retry fast again.
      monitor.startMonitoring();
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
