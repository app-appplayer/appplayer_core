import 'dart:async';

import '../logging/logger.dart';
import 'connection_info.dart';
import 'connection_manager.dart';
import 'connection_state.dart';

/// Configuration for [ConnectionHealthMonitor] (NFR-REL-001~003).
class HealthMonitorConfig {
  const HealthMonitorConfig({
    this.checkInterval = const Duration(seconds: 30),
    this.maxReconnectAttempts = 0,
    this.reconnectDelay = const Duration(seconds: 5),
    this.maxReconnectDelay = const Duration(seconds: 30),
  });

  factory HealthMonitorConfig.defaults() => const HealthMonitorConfig();

  /// How often health is swept: keepalive pings on transient links, plus the
  /// scan for `error` entries to reconnect. This is a DETECTION cadence only —
  /// retry pacing is [reconnectDelay]/[maxReconnectDelay], so a host may make
  /// detection fast without also making retries hammer.
  final Duration checkInterval;

  /// Retry ceiling per server. `0` (the default) means **never give up while
  /// monitoring runs** — an open app keeps trying, paced by the backoff below.
  ///
  /// A positive value caps attempts and the server is abandoned until something
  /// calls [resetReconnectAttempts] (or the app reopens / resumes). That was the
  /// old default and it stranded live apps: the counter only clears when a check
  /// observes `connected`, which can never happen once retrying has stopped.
  final int maxReconnectAttempts;

  /// First backoff step. Each further consecutive failure doubles it, capped at
  /// [maxReconnectDelay].
  final Duration reconnectDelay;

  /// Backoff ceiling. This — not an attempt count — is what keeps a dead server
  /// from being dialled every couple of seconds forever.
  final Duration maxReconnectDelay;
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

  /// Servers with a scheduled reconnect already waiting out its backoff. Without
  /// this, every sweep tick would stack another attempt on top of the pending
  /// one — with a 2s tick and a 30s backoff that is 15 dials for one drop.
  final Set<String> _pending = {};

  /// Servers already reported as exhausted, so the warning is logged on the
  /// transition instead of on every tick.
  final Set<String> _exhausted = {};

  /// Waiting retries, keyed by server, so [retryNow] can cut a wait short
  /// instead of letting a hint sit behind a backoff that is already running.
  final Map<String, Completer<void>> _wakes = {};

  /// Bumped on every start/stop so a reconnect waiting out its backoff can tell
  /// that monitoring was stopped (or restarted) underneath it and stand down.
  int _generation = 0;
  Timer? _timer;

  void startMonitoring() {
    stopMonitoring();
    _generation++;
    // A fresh start means a fresh situation — a foreground return, a resume.
    // Whatever backoff had grown while things were failing does not apply to it.
    _reconnectAttempts.clear();
    _pending.clear();
    _exhausted.clear();
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
    _generation++;
    _pending.clear();
    _logger.info('Health monitoring stopped');
  }

  /// FR-HEALTH-006 / NFR-REL-004
  void resetReconnectAttempts(String serverId) {
    _reconnectAttempts[serverId] = 0;
    _exhausted.remove(serverId);
  }

  /// A host signal that this server may be reachable again — the network came
  /// back, the board was sighted on the discovery axis, the user asked. The
  /// waiting retry stops waiting and dials now (FR-HEALTH-008).
  ///
  /// This is the door every such signal comes through, whatever the transport.
  /// A timer can only guess when to look again; a signal knows. Where one
  /// exists the interval stops deciding recovery latency — which is why the
  /// interval does not have to be tuned aggressively to be good enough.
  void retryNow(String serverId) {
    _reconnectAttempts[serverId] = 0;
    _exhausted.remove(serverId);

    final wake = _wakes[serverId];
    if (wake != null && !wake.isCompleted) {
      _logger.info('Reachability hint — dialling now', {'serverId': serverId});
      wake.complete();
      return;
    }
    // A dial is already running: it will report on its own. Hinting harder
    // cannot make an in-flight connect finish sooner.
    if (_pending.contains(serverId)) return;

    final info = _conn.getConnection(serverId);
    if (info == null || info.state != ConnectionState.error) return;
    _logger.info('Reachability hint — dialling now', {'serverId': serverId});
    _reconnectAttempts[serverId] = 1;
    _pending.add(serverId);
    unawaited(_reconnectAfterBackoff(serverId, Duration.zero, 1, _generation));
  }

  /// Same signal without a server in mind — connectivity returned, so anything
  /// that is down might be up. Applies to every failed connection, which is how
  /// remote/cloud servers get served: they have no discovery axis to be sighted
  /// on, so the network itself is their only event source.
  void retryAllNow() {
    for (final entry in _conn.connections.entries.toList()) {
      if (entry.value.state == ConnectionState.error) retryNow(entry.key);
    }
  }

  int getReconnectAttempts(String serverId) =>
      _reconnectAttempts[serverId] ?? 0;

  /// Backoff for the [attempts]-th consecutive failure (0-based), capped at
  /// [HealthMonitorConfig.maxReconnectDelay]. Exposed for tests and for hosts
  /// that want to show "retrying in …".
  ///
  /// [engaged] servers do not back off at all: an app open on screen is an
  /// explicit statement that this connection is supposed to exist, and the user
  /// is watching it fail. Widening the gap there buys nothing — the point of
  /// widening it is to stop dialling a server nobody is looking at.
  Duration backoffFor(int attempts, {bool engaged = false}) {
    final base = _config.reconnectDelay.inMilliseconds;
    if (base <= 0) return Duration.zero;
    if (engaged) return Duration(milliseconds: base);
    final ceiling = _config.maxReconnectDelay.inMilliseconds;
    var ms = base;
    for (var i = 0; i < attempts && ms < ceiling; i++) {
      ms *= 2;
    }
    return Duration(milliseconds: ms < ceiling ? ms : ceiling);
  }

  /// Whether a server currently has an app open on it. Host-supplied because
  /// "open" is a runtime/session fact the connection layer cannot see. Null (the
  /// default) means every server is treated as idle — the backoff applies to all
  /// of them, which is the behaviour before this seam existed.
  ///
  /// Note this is deliberately NOT "appears on the dashboard": a tile is not
  /// someone waiting on the screen, and treating every tiled server as engaged
  /// would dial the whole home screen every second forever.
  bool Function(String serverId)? isEngaged;

  Future<void> _performHealthCheck() async {
    // Keepalive + active liveness for transient stream links (BLE etc.): warms
    // the link so it drops far less often, and flips a silently-dead link to
    // error so the reconnect pass below picks it up this same tick.
    await _conn.keepAliveSweep();
    final entries = _conn.connections.entries.toList();
    for (final entry in entries) {
      final info = entry.value;
      if (info.state == ConnectionState.error) {
        _handleFailedConnection(entry.key, info);
      } else if (info.state == ConnectionState.connected) {
        _reconnectAttempts[entry.key] = 0; // FR-HEALTH-005
        _exhausted.remove(entry.key);
      }
    }
  }

  /// Schedules a reconnect for a failed server. Does NOT await the backoff — the
  /// sweep must stay short so one server's 30s wait cannot delay the next
  /// server's detection.
  void _handleFailedConnection(String serverId, ConnectionInfo info) {
    if (_pending.contains(serverId)) return;

    final attempts = _reconnectAttempts[serverId] ?? 0;
    final engaged = isEngaged?.call(serverId) ?? false;
    final max = _config.maxReconnectAttempts;
    if (max > 0 && attempts >= max && !engaged) {
      if (_exhausted.add(serverId)) {
        _logger.warn('Max reconnect attempts reached — giving up', {
          'serverId': serverId,
          'attempts': attempts,
        });
      }
      return;
    }

    _reconnectAttempts[serverId] = attempts + 1;
    _pending.add(serverId);
    unawaited(_reconnectAfterBackoff(
      serverId,
      backoffFor(attempts, engaged: engaged),
      attempts + 1,
      _generation,
    ));
  }

  Future<void> _reconnectAfterBackoff(
    String serverId,
    Duration firstDelay,
    int attempt,
    int generation,
  ) async {
    var delay = firstDelay;
    try {
      // Engaged servers re-arm from inside this loop instead of waiting for the
      // next sweep to notice the failure. Sweep-driven rescheduling makes the
      // real spacing `delay + up to one checkInterval`, so the fixed 1s a host
      // asked for arrives as 1-3s. An app on screen should retry on the pace it
      // was given, not on the pace of the detection sweep.
      while (true) {
        _logger.info('Reconnect scheduled', {
          'serverId': serverId,
          'attempt': attempt,
          'inMs': delay.inMilliseconds,
          'max': _config.maxReconnectAttempts == 0
              ? 'unlimited'
              : _config.maxReconnectAttempts,
        });
        // Waiting, but interruptible: a reachability hint (retryNow) completes
        // the wake and the dial happens at once rather than at the end of an
        // interval chosen without knowing anything.
        final wake = Completer<void>();
        _wakes[serverId] = wake;
        try {
          await Future.any<void>([Future<void>.delayed(delay), wake.future]);
        } finally {
          _wakes.remove(serverId);
        }
        if (generation != _generation) return; // monitoring stopped/restarted

        final result = await _conn.reconnect(serverId);
        if (generation != _generation) return;
        if (result.success) {
          _reconnectAttempts[serverId] = 0;
          _exhausted.remove(serverId);
          _logger.info('Reconnect succeeded', {'serverId': serverId});
          return;
        }
        _logger.warn('Reconnect failed', {
          'serverId': serverId,
          'error': result.error,
        });

        // Hand back to the sweep unless the app is still open on this server…
        if (!(isEngaged?.call(serverId) ?? false)) return;
        // …and the server is still one we hold a connection entry for. Without
        // this the loop would keep dialling a serverId that was disconnected or
        // removed, which can only ever fail.
        if (_conn.getConnection(serverId) == null) return;
        _reconnectAttempts[serverId] = ++attempt;
        delay = backoffFor(attempt - 1, engaged: true);
      }
    } catch (e, st) {
      _logger.logError('Reconnect threw', e, st, {'serverId': serverId});
    } finally {
      // Only clear our own claim: a stale generation's chain must not release a
      // slot the current generation is holding.
      if (generation == _generation) _pending.remove(serverId);
    }
  }
}
