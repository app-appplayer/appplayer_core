import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../logging/logger.dart';

/// Routes MCP `notifications/resources/updated` messages into the runtime
/// (MOD-RUNTIME-005, FR-RES-005~006).
class NotificationRouter {
  NotificationRouter({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;

  /// FR-RES-005
  void register({
    required Client client,
    required MCPUIRuntime runtime,
  }) {
    _logger.debug('Registering notification handlers');

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
  }
}
