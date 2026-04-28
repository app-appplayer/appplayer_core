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

  Map<String, ConnectionInfo> get connections =>
      Map.unmodifiable(_connections);

  bool hasConnection(String serverId) =>
      _connections.containsKey(serverId);

  ConnectionInfo? getConnection(String serverId) => _connections[serverId];

  /// FR-CONN-001~003, 010
  Future<ConnectionResult> connect(ServerConfig server) async {
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
      notifyListeners();

      _logger.info('Connected', {'serverId': server.id});
      return ConnectionResult.success(info);
    } catch (e, st) {
      info.state = ConnectionState.error;
      info.error = e.toString();
      notifyListeners();
      _logger.logError('Connect failed', e, st, {'serverId': server.id});
      return ConnectionResult.failure(e.toString());
    }
  }

  /// FR-CONN-004
  Future<void> disconnect(String serverId) async {
    final info = _connections[serverId];
    if (info == null) return;

    _logger.debug('Disconnecting', {'serverId': serverId});
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
