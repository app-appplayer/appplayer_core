import 'package:flutter/widgets.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';

import '../dashboard/dashboard_orchestrator.dart';
import '../logging/logger.dart';
import 'app_handle.dart';
import 'dashboard_session.dart';

/// Concrete [DashboardSession]. The orchestrator already mounts slot
/// runtimes into the main runtime state during open; this session is a thin
/// public wrapper over the main runtime (MOD-SESSION-002).
class DashboardSessionImpl implements DashboardSession {
  DashboardSessionImpl({
    required this.handle,
    required MCPUIRuntime runtime,
    required DashboardOrchestrator orchestrator,
    required Logger logger,
  })  : _runtime = runtime,
        _orchestrator = orchestrator,
        _logger = logger;

  @override
  final AppHandle handle;

  final MCPUIRuntime _runtime;
  final DashboardOrchestrator _orchestrator;
  final Logger _logger;

  bool _closed = false;

  @override
  Widget buildWidget({required BuildContext context}) {
    return _runtime.buildUI(context: context);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _orchestrator.close();
    } catch (e, st) {
      _logger.logError('dashboard.session.close.fail', e, st,
          {'handle': handle.toString()});
    }
  }
}
