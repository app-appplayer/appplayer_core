import 'dart:async';

import '../logging/logger.dart';
import 'connection_info.dart';
import 'connection_manager.dart';
import 'connection_state.dart';

/// Configuration for [ConnectionHealthMonitor] (NFR-REL-001~003).
class HealthMonitorConfig {
  const HealthMonitorConfig({
    this.checkInterval = const Duration(seconds: 30),
    this.maxReconnectAttempts = 3,
    this.reconnectDelay = const Duration(seconds: 5),
  });

  factory HealthMonitorConfig.defaults() => const HealthMonitorConfig();

  final Duration checkInterval;
  final int maxReconnectAttempts;
  final Duration reconnectDelay;
}

/// Periodically checks connection health and attempts auto-reconnect
/// for failed servers (MOD-CONN-003, FR-HEALTH-001~006).
class ConnectionHealthMonitor {
  ConnectionHealthMonitor({
    required ConnectionManager conn,
    HealthMonitorConfig? config,
    Logger? logger,
  })  : _conn = conn,
        _config = config ?? HealthMonitorConfig.defaults(),
        _logger = logger ?? NoopLogger();

  final ConnectionManager _conn;
  final HealthMonitorConfig _config;
  final Logger _logger;
  final Map<String, int> _reconnectAttempts = {};
  Timer? _timer;

  void startMonitoring() {
    stopMonitoring();
    _logger.info('Health monitoring started');
    // Immediate first pass (FR-HEALTH-001).
    unawaited(_performHealthCheck());
    _timer = Timer.periodic(
      _config.checkInterval,
      (_) => unawaited(_performHealthCheck()),
    );
  }

  void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
    _logger.info('Health monitoring stopped');
  }

  /// FR-HEALTH-006 / NFR-REL-004
  void resetReconnectAttempts(String serverId) {
    _reconnectAttempts[serverId] = 0;
  }

  int getReconnectAttempts(String serverId) =>
      _reconnectAttempts[serverId] ?? 0;

  Future<void> _performHealthCheck() async {
    final entries = _conn.connections.entries.toList();
    for (final entry in entries) {
      final info = entry.value;
      if (info.state == ConnectionState.error) {
        await _handleFailedConnection(entry.key, info);
      } else if (info.state == ConnectionState.connected) {
        _reconnectAttempts[entry.key] = 0; // FR-HEALTH-005
      }
    }
  }

  Future<void> _handleFailedConnection(
    String serverId,
    ConnectionInfo info,
  ) async {
    final attempts = _reconnectAttempts[serverId] ?? 0;
    if (attempts >= _config.maxReconnectAttempts) {
      _logger.warn('Max reconnect attempts reached', {
        'serverId': serverId,
        'attempts': attempts,
      });
      return;
    }

    _reconnectAttempts[serverId] = attempts + 1;
    _logger.info('Attempting reconnect', {
      'serverId': serverId,
      'attempt': attempts + 1,
      'max': _config.maxReconnectAttempts,
    });

    await Future<void>.delayed(_config.reconnectDelay);

    try {
      final result = await _conn.reconnect(serverId);
      if (result.success) {
        _logger.info('Reconnect succeeded', {'serverId': serverId});
      } else {
        _logger.warn('Reconnect failed', {
          'serverId': serverId,
          'error': result.error,
        });
      }
    } catch (e, st) {
      _logger.logError('Reconnect threw', e, st, {'serverId': serverId});
    }
  }
}
