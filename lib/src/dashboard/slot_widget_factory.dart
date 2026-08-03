import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';

import '../logging/logger.dart';
import '../runtime/runtime_manager.dart';
import 'dashboard_orchestrator.dart';

/// Draws the device bound to a dashboard slot.
///
/// A dashboard bundle lays its own slots out — that is the point of Dashboard
/// Mode, as against the host arranging tiles in a grid of its own. The layout
/// reaches the runtime as `{"type": "slot", "slotId": …}` nodes, and until now
/// nothing rendered them: the bundle could describe a dashboard that the
/// runtime could not draw.
///
/// `slot` is a host widget rather than a DSL one — it means nothing outside a
/// dashboard, and its content is a whole other runtime — so it is registered
/// on the dashboard runtime. Schema validation accepts it because the runtime
/// consults its own widget registry before rejecting a type.
class SlotWidgetFactory extends WidgetFactory {
  SlotWidgetFactory({
    required RuntimeManager runtimeManager,
    Logger? logger,
  })  : _runtimes = runtimeManager,
        _logger = logger ?? NoopLogger();

  final RuntimeManager _runtimes;
  final Logger _logger;

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final slotId = context.resolve<String?>(properties['slotId']);
    if (slotId == null || slotId.isEmpty) {
      // A slot with no id names no position, so there is nothing to bind it
      // to. Reported rather than drawn as an empty box, which would look like
      // a deliberate gap in the layout.
      _logger.warn('dashboard.slot.missing_id', {'definition': definition});
      return const _SlotMessage(text: 'Slot has no id', isError: true);
    }

    // §3.5.5 — both of these are the host's, written as it binds.
    final error = context.getValue<String>('slot.$slotId.error');
    if (error != null && error.isNotEmpty) {
      return _SlotMessage(text: error, isError: true);
    }

    final deviceId = context.getValue<String>('slot.$slotId.deviceId');
    if (deviceId == null || deviceId.isEmpty) {
      // Devices arrive asynchronously. A slot waiting for one is pending, not
      // failed, and §3.5.5 says to render it as such.
      return const _SlotMessage(text: 'Waiting for device…');
    }

    final runtime = _runtimes.getRuntime(
      DashboardOrchestrator.deviceSummaryRuntimeHandle(deviceId),
    );
    if (runtime == null || !runtime.isInitialized) {
      return const _SlotMessage(text: 'Waiting for device…');
    }

    final buildContext = context.buildContext;
    if (buildContext == null) {
      _logger.warn('dashboard.slot.no_build_context', {'slotId': slotId});
      return const _SlotMessage(text: 'Waiting for device…');
    }
    return runtime.buildUI(context: buildContext);
  }
}

class _SlotMessage extends StatelessWidget {
  const _SlotMessage({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isError ? scheme.error : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
