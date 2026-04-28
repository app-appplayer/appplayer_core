import 'package:mcp_client/mcp_client.dart' hide ConnectionState;

import '../model/server_config.dart';
import 'connection_state.dart';

/// Runtime record of an MCP connection attempt and its current state.
///
/// Mutable on purpose: [ConnectionManager] updates [state], [client],
/// [connectedAt], and [error] in place and notifies listeners, matching the
/// original `basic/` behavior.
class ConnectionInfo {
  ConnectionInfo({
    required this.serverId,
    required this.serverName,
    required this.serverConfig,
    required this.state,
    this.client,
    this.connectedAt,
    this.error,
  });

  final String serverId;
  final String serverName;
  final ServerConfig serverConfig;
  ConnectionState state;
  Client? client;
  DateTime? connectedAt;
  String? error;

  bool get isHealthy =>
      state == ConnectionState.connected && client != null;

  Duration? get connectionDuration =>
      connectedAt == null ? null : DateTime.now().difference(connectedAt!);
}
