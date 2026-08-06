/// Reconnect-based connection continuity (FR-CONT).
///
/// Concrete [ContinuityController] backed by [ConnectionManager]. When the app
/// enters the background the OS suspends the process and IP sockets drop; this
/// controller snapshots which servers were live, releases their clients, and
/// re-establishes them on foreground return (or on a background wake sweep).
///
/// **Event-replay catch-up** (replaying messages missed while suspended) needs
/// a transport resumption token (SSE `Last-Event-ID`). The resolved
/// `mcp_client` transport does not surface one, so [ResumeCursor.lastEventId]
/// is reserved but stays null until that capability lands; continuity today is
/// reconnect + fresh server state.
library;

import '../logging/logger.dart';
import '../model/server_config.dart';
import 'connection_health_monitor.dart';
import 'connection_manager.dart';
import 'connection_state.dart';
import 'continuity_controller.dart';

/// A snapshot of a paused connection, used to re-establish it.
class ResumeCursor {
  const ResumeCursor({required this.serverConfig, this.lastEventId});

  final ServerConfig serverConfig;

  /// Transport resumption token (SSE `Last-Event-ID`). Reserved for
  /// event-replay catch-up; null until the transport surfaces it.
  final String? lastEventId;

  String get serverId => serverConfig.id;
}

class ConnectionContinuity implements ContinuityController {
  ConnectionContinuity({
    required ConnectionManager connections,
    ConnectionHealthMonitor? healthMonitor,
    Logger? logger,
  })  : _connections = connections,
        _healthMonitor = healthMonitor,
        _logger = logger ?? NoopLogger();

  final ConnectionManager _connections;
  final ConnectionHealthMonitor? _healthMonitor;
  final Logger _logger;

  /// Servers that were live when the app was backgrounded, keyed by serverId.
  final Map<String, ResumeCursor> _paused = {};

  /// Whether continuity is currently in the paused (backgrounded) state.
  bool get isPaused => _paused.isNotEmpty;

  /// Resume cursors captured at the last [pauseAll]. Exposed for inspection.
  Map<String, ResumeCursor> get pausedCursors => Map.unmodifiable(_paused);

  @override
  Future<void> pauseAll() async {
    final live = _connections.connections.values
        .where((c) => c.state != ConnectionState.error)
        .toList();
    if (live.isEmpty) {
      _logger.debug('continuity.pause.none');
      return;
    }

    _healthMonitor?.stopMonitoring();
    for (final info in live) {
      _paused[info.serverId] = ResumeCursor(serverConfig: info.serverConfig);
      await _connections.disconnect(info.serverId);
    }
    _logger.info('continuity.paused', {'count': _paused.length});
  }

  @override
  Future<void> resumeAll() async {
    if (_paused.isEmpty) {
      // Nothing was paused (e.g. keepAlive kept sockets alive) — just make sure
      // any connection that dropped while backgrounded is swept.
      await sweepStale();
      _healthMonitor?.startMonitoring();
      return;
    }

    final cursors = _paused.values.toList();
    _paused.clear();
    for (final cursor in cursors) {
      final result = await _connections.connect(cursor.serverConfig);
      if (result.success) {
        _logger.info('continuity.resumed', {'serverId': cursor.serverId});
      } else {
        _logger.warn('continuity.resume.failed', {
          'serverId': cursor.serverId,
          'error': result.error,
        });
      }
    }
    _healthMonitor?.startMonitoring();
  }

  @override
  Future<void> sweepStale() async {
    final stale = _connections.connections.values
        .where((c) => c.state == ConnectionState.error)
        .map((c) => c.serverId)
        .toList();
    for (final serverId in stale) {
      _logger.info('continuity.sweep.reconnect', {'serverId': serverId});
      // A wake is new information (a peripheral signalled, a push landed), so
      // whatever backoff had grown while the link was dead does not describe
      // this moment — clear it so the monitor's next pass starts fast again.
      _healthMonitor?.resetReconnectAttempts(serverId);
      await _connections.reconnect(serverId);
    }
  }
}
