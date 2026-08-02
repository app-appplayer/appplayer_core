import 'package:flutter/foundation.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;

import '../logging/logger.dart';
import '../model/server_config.dart';
import 'connection_info.dart';
import 'connection_result.dart';
import 'connection_state.dart';
import 'transport_factory.dart';

/// Abstraction over `McpClient.createAndConnect` to allow injection in tests.
typedef ClientConnector = Future<Client> Function(TransportConfig transport);

/// Host-provided token re-grant for durable reconnect.
///
/// A marketplace server's credential is a short-lived per-user connectionToken
/// baked into [ServerConfig.transportConfig] `accessToken`. When a connect
/// attempt fails and the token may be stale, the manager calls this hook with
/// the stale config; the host re-grants a fresh token (silently, via the
/// marketplace session), persists it, and returns the refreshed [ServerConfig].
/// Returning null (or an unchanged token) means "no re-grant available" — the
/// original failure surfaces unchanged.
///
/// Optional: when no hook is wired, connect/reconnect behave exactly as before
/// (static token or no-auth). Only token-bearing servers whose host supplies a
/// hook are affected — hand-typed URLs, discovered boards (tcp/ble/serial) and
/// no-auth servers are untouched.
typedef ServerReGrant = Future<ServerConfig?> Function(ServerConfig stale);

Future<Client> _defaultConnector(TransportConfig transport) async {
  final config = McpClient.simpleConfig(
    name: 'AppPlayer Client',
    version: '1.0.0',
  );
  final result = await McpClient.createAndConnect(
    config: config,
    transportConfig: transport,
  );
  if (result.isFailure) {
    throw StateError('Failed to connect: ${result.failureOrNull}');
  }
  return result.get();
}

/// Manages MCP server connections: create, reuse, disconnect, reconnect,
/// and notify listeners on state changes (MOD-CONN-001, FR-CONN-001~010).
class ConnectionManager extends ChangeNotifier {
  ConnectionManager({
    Logger? logger,
    TransportFactory? transportFactory,
    ClientConnector? connector,
    Duration? waitCheckInterval,
    Duration? waitMaxDuration,
  })  : _logger = logger ?? NoopLogger(),
        _transportFactory = transportFactory ?? const TransportFactory(),
        _connector = connector ?? _defaultConnector,
        _waitCheckInterval =
            waitCheckInterval ?? const Duration(milliseconds: 100),
        _waitMaxDuration = waitMaxDuration ?? const Duration(seconds: 30);

  final Logger _logger;
  final TransportFactory _transportFactory;
  final ClientConnector _connector;
  final Duration _waitCheckInterval;
  final Duration _waitMaxDuration;
  final Map<String, ConnectionInfo> _connections = {};

  /// Optional durable-reconnect hook (see [ServerReGrant]). Mutable so the host
  /// can wire it after the marketplace session exists (the core / manager is
  /// built at composition time, before the marketplace capabilities). Null =
  /// no re-grant; connect/reconnect stay byte-for-byte as before.
  ServerReGrant? tokenReGrant;

  /// Called after a server's [Client] is replaced by a NEW one — the first
  /// connect and every reconnect alike.
  ///
  /// State that lives on the CLIENT does not survive the swap: notification
  /// handlers and `resources/subscribe` are per-connection, so an open app
  /// that was streaming goes silent after a background round trip while its
  /// tool calls keep working (those resolve the live client per call). The
  /// screen looked healthy and only the stream was dead, and pressing
  /// Subscribe again did nothing because the runtime had already registered
  /// its binding. Whoever owns that state re-attaches here.
  void Function(String serverId, Client client)? onClientAttached;

  Map<String, ConnectionInfo> get connections =>
      Map.unmodifiable(_connections);

  bool hasConnection(String serverId) =>
      _connections.containsKey(serverId);

  ConnectionInfo? getConnection(String serverId) => _connections[serverId];

  /// FR-CONN-001~003, 010
  Future<ConnectionResult> connect(ServerConfig server) =>
      // Allow one durable-reconnect re-grant on the outer attempt; the retry
      // (with a fresh token) runs with allowReGrant:false so a persistently
      // bad server can't loop.
      _connect(server, allowReGrant: true);

  Future<ConnectionResult> _connect(
    ServerConfig server, {
    required bool allowReGrant,
  }) async {
    final existing = _connections[server.id];
    if (existing != null) {
      if (existing.state == ConnectionState.connected) {
        _logger.debug('Reusing connection', {'serverId': server.id});
        return ConnectionResult.success(existing);
      }
      if (existing.state == ConnectionState.connecting) {
        _logger.debug('Awaiting in-flight connection',
            {'serverId': server.id});
        return _waitForConnection(server.id);
      }
    }

    _logger.debug('Creating connection', {'serverId': server.id});
    final info = ConnectionInfo(
      serverId: server.id,
      serverName: server.name,
      serverConfig: server,
      state: ConnectionState.connecting,
    );
    _connections[server.id] = info;
    notifyListeners();

    try {
      final transport = _transportFactory.create(server);
      final client = await _connector(transport);

      info.client = client;
      info.state = ConnectionState.connected;
      info.connectedAt = DateTime.now();
      // Liveness: when the transport drops on its own — BLE supervision
      // timeout, a server closing the socket — mcp_client fires onDisconnect.
      // Without reacting, this entry stays `connected` forever: the launcher
      // badge stays lit and a retry reuses the dead client (readResource hangs
      // on a link that is gone) instead of dialing again. React by dropping
      // the entry so hasConnection()/isServerConnected() tell the truth and the
      // next connect() starts fresh.
      info.disconnectSub = client.onDisconnect.listen(
        (reason) => _handleTransportDrop(server.id, reason),
      );
      notifyListeners();
      // After the entry is live, so a re-attach can resolve the connection it
      // is re-attaching to.
      final attached = onClientAttached;
      if (attached != null) {
        try {
          attached(server.id, client);
        } catch (e, st) {
          _logger.logError(
              'onClientAttached hook threw', e, st, {'serverId': server.id});
        }
      }

      _logger.info('Connected', {'serverId': server.id});
      return ConnectionResult.success(info);
    } catch (e, st) {
      // Durable reconnect (MOD-CONN): a marketplace server's connectionToken is
      // a short-lived per-user JWS baked into transportConfig. If it went stale
      // the connect (MCP initialize) fails auth. When a re-grant hook is wired
      // AND this server carries a bearer token, refresh it once and retry — the
      // fresh open re-initialises with a valid token. This runs for
      // openAppFromServer, reconnect() and ConnectionHealthMonitor alike, since
      // all three funnel through connect(). No hook / no token → skipped, and
      // the original failure surfaces unchanged (byte-for-byte prior behaviour).
      if (allowReGrant && tokenReGrant != null && _hasBearerToken(server)) {
        final fresh = await _reGrant(server);
        if (fresh != null) {
          _connections.remove(server.id);
          notifyListeners();
          return _connect(fresh, allowReGrant: false);
        }
      }
      info.state = ConnectionState.error;
      info.error = e.toString();
      notifyListeners();
      _logger.logError('Connect failed', e, st, {'serverId': server.id});
      return ConnectionResult.failure(e.toString());
    }
  }

  bool _hasBearerToken(ServerConfig server) =>
      (server.transportConfig['accessToken'] as String?)?.isNotEmpty ?? false;

  /// Invoke the host re-grant hook. Returns a refreshed [ServerConfig] only when
  /// the hook produced a genuinely new token; otherwise null (→ surface the
  /// original failure). Hook errors are swallowed to a null so a failing
  /// re-grant never masks the real connect error.
  Future<ServerConfig?> _reGrant(ServerConfig stale) async {
    try {
      final fresh = await tokenReGrant!(stale);
      if (fresh != null &&
          fresh.transportConfig['accessToken'] !=
              stale.transportConfig['accessToken']) {
        _logger.info('Re-granted server token — retrying connect',
            {'serverId': stale.id});
        return fresh;
      }
    } catch (e, st) {
      _logger.logError('Token re-grant failed', e, st, {'serverId': stale.id});
    }
    return null;
  }

  /// Transport dropped on its own (not an explicit [disconnect] call). Mark the
  /// entry `error` and clear the dead client, but KEEP it in the map so:
  ///   - `isServerConnected` reads false (state != connected) → the launcher
  ///     badge clears and any open session's dynamic `client` getter goes null
  ///     instead of dialing a corpse;
  ///   - [ConnectionHealthMonitor] sees the `error` state and auto-reconnects,
  ///     which is what lets a flaky link (e.g. the ESP32 BLE controller that
  ///     hard-drops every ~45s) self-heal without the user reopening the app —
  ///     a fresh client lands back under the same serverId and the session
  ///     picks it up.
  /// Removing the entry instead would hide it from the monitor and there would
  /// be nothing to reconnect. Idempotent.
  void _handleTransportDrop(String serverId, DisconnectReason reason) {
    final info = _connections[serverId];
    if (info == null) return;
    info.disconnectSub?.cancel();
    info.disconnectSub = null;
    info.client = null;
    info.state = ConnectionState.error;
    info.error = 'transport dropped: $reason';
    _logger.info('Transport dropped — marked for reconnect',
        {'serverId': serverId, 'reason': reason.toString()});
    notifyListeners();
  }

  /// Active keepalive + liveness for transient stream transports (ble:// /
  /// tcp:// / serial:// carried on a streamableHttp config). Sends a cheap
  /// `listResources` round-trip on every such CONNECTED link:
  ///   - the traffic keeps the link warm — an idle BLE session to an ESP32
  ///     drops in ~15s, but ~2-3s keepalive traffic stretches it to ~45s
  ///     (measured), so far fewer reconnect cycles;
  ///   - a probe that fails/times out means the link died silently, so the
  ///     entry is marked error (via [_handleTransportDrop]) and the health
  ///     monitor reconnects it.
  /// HTTP/SSE/stdio servers are skipped — they don't suffer idle-drop and a
  /// periodic poll would just be noise.
  Future<void> keepAliveSweep({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final targets = _connections.entries
        .where((e) =>
            e.value.state == ConnectionState.connected &&
            e.value.client != null &&
            _isTransientStream(e.value.serverConfig))
        .toList();
    for (final e in targets) {
      final client = e.value.client!;
      try {
        await client.listResources().timeout(timeout);
      } catch (_) {
        _handleTransportDrop(e.key, DisconnectReason.transportError);
      }
    }
  }

  static bool _isTransientStream(ServerConfig server) {
    if (server.transportType != TransportType.streamableHttp) return false;
    final base = server.transportConfig['baseUrl'];
    return base is String &&
        (base.startsWith('ble://') ||
            base.startsWith('tcp://') ||
            base.startsWith('serial://'));
  }

  /// FR-CONN-004
  Future<void> disconnect(String serverId) async {
    final info = _connections[serverId];
    if (info == null) return;

    _logger.debug('Disconnecting', {'serverId': serverId});
    // Cancel the liveness listener first so tearing the client down does not
    // re-enter _handleTransportDrop for a disconnect we are performing.
    await info.disconnectSub?.cancel();
    info.disconnectSub = null;
    try {
      info.client?.disconnect();
    } catch (e, st) {
      _logger.warn('Disconnect error', {'serverId': serverId}, e);
      _logger.logError('Disconnect stack', e, st, {'serverId': serverId});
    }

    _connections.remove(serverId);
    notifyListeners();
  }

  /// FR-CONN-005
  Future<void> disconnectAll() async {
    _logger.debug('Disconnecting all', {'count': _connections.length});
    for (final info in _connections.values) {
      await info.disconnectSub?.cancel();
      info.disconnectSub = null;
      try {
        info.client?.disconnect();
      } catch (e) {
        _logger.warn('Disconnect error',
            {'serverId': info.serverId}, e);
      }
    }
    _connections.clear();
    notifyListeners();
  }

  /// FR-CONN-006
  Future<ConnectionResult> reconnect(String serverId) async {
    final existing = _connections[serverId];
    if (existing == null) {
      return ConnectionResult.failure('No connection found for server');
    }
    final server = existing.serverConfig;
    await disconnect(serverId);
    return connect(server);
  }

  /// FR-CONN-003, 010
  Future<ConnectionResult> _waitForConnection(String serverId) async {
    // Iteration-based loop (not wall clock) so it behaves correctly under
    // fakeAsync in tests.
    final maxIterations = _waitCheckInterval.inMilliseconds == 0
        ? 1
        : _waitMaxDuration.inMilliseconds ~/
            _waitCheckInterval.inMilliseconds;

    for (var i = 0; i < maxIterations; i++) {
      final info = _connections[serverId];
      if (info == null) {
        return ConnectionResult.failure('Connection cancelled');
      }
      if (info.state == ConnectionState.connected) {
        return ConnectionResult.success(info);
      }
      if (info.state == ConnectionState.error) {
        return ConnectionResult.failure(
            info.error ?? 'Connection failed');
      }
      await Future<void>.delayed(_waitCheckInterval);
    }

    return ConnectionResult.failure('Connection timeout');
  }
}
