import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../logging/logger.dart';

/// Callback invoked when a `notifications/message` (MCP logging spec)
/// arrives. Hosts typically push the payload into a `LogBuffer` for the
/// in-app log viewer.
typedef McpLogMessageHandler = void Function(
    String serverId, Map<String, dynamic> params);

/// Routes MCP server-initiated notifications into the runtime / host:
///   - `notifications/resources/updated` → runtime resource refresh
///     (MOD-RUNTIME-005, FR-RES-005~006).
///   - `notifications/message` → host-provided log handler (MCP logging
///     spec; client controls verbosity via `logging/setLevel`).
class NotificationRouter {
  NotificationRouter({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;

  /// FR-RES-005 + MCP logging spec.
  ///
  /// [onMcpLogMessage] receives the raw MCP `notifications/message`
  /// payload (`{level, logger?, data}` per spec). The router itself does
  /// not interpret `level`; mapping into the host's log model is the
  /// caller's responsibility.
  void register({
    required Client client,
    required MCPUIRuntime runtime,
    String? serverId,
    McpLogMessageHandler? onMcpLogMessage,
  }) {
    _logger.debug('Registering notification handlers',
        {'serverId': serverId});

    client.onNotification('notifications/resources/updated',
        (params) async {
      try {
        _logger.debug('Resource update notification', {'params': params});
        if (!runtime.isInitialized) return;

        await runtime.handleNotification(
          {
            'method': 'notifications/resources/updated',
            'params': params,
          },
          resourceReader: (uri) async {
            final res = await client.readResource(uri);
            if (res.contents.isEmpty) return '{}';
            return res.contents.first.text ?? '{}';
          },
        );
      } catch (e, st) {
        _logger.logError('handleNotification failed', e, st);
      }
    });

    if (onMcpLogMessage != null && serverId != null) {
      client.onNotification('notifications/message', (params) async {
        try {
          onMcpLogMessage(serverId, params);
        } catch (e, st) {
          _logger.logError(
              'mcp log notification handler failed', e, st, {'serverId': serverId});
        }
      });
    }
  }
}
