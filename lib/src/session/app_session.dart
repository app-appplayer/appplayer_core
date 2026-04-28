import 'package:flutter/widgets.dart';

import '../metadata/app_metadata.dart';
import 'app_handle.dart';

/// Public session handle for a single opened app (MOD-SESSION-001,
/// FR-SESSION-001~004).
///
/// Hosts consume sessions via [buildWidget]; the underlying `MCPUIRuntime`
/// and tool/resource/notification wiring are owned internally and never
/// exposed through the public API.
abstract class AppSession {
  AppHandle get handle;
  AppSource get source;
  AppMetadata? get metadata;

  /// Builds the Flutter widget tree for this session. Tool call / resource
  /// subscribe / notification routing are wired inside — hosts do not need
  /// to pass callbacks.
  Widget buildWidget({
    required BuildContext context,
    VoidCallback? onExit,
  });

  /// Spec §11.9 dashboard rendering entry point. Returns `null` when the
  /// DSL declares no `dashboard` block — the host should fall back to a
  /// default card derived from [metadata] per §11.9.1. The returned
  /// widget hosts only the `dashboard.content` subtree and re-evaluates
  /// bindings on `dashboard.refreshInterval`.
  ///
  /// [onOpenApp] is invoked for DSL `navigation:openApp` actions (spec
  /// §4.3.1) fired from within the dashboard subtree — hosts use this
  /// to transition the launcher to the full application view.
  Widget? buildDashboardWidget({
    required BuildContext context,
    VoidCallback? onExit,
    void Function(String? appId, String? route)? onOpenApp,
  });

  /// Unsubscribe resources and destroy the underlying runtime. The server
  /// connection (if any) is not terminated because another session may be
  /// sharing it — hosts disconnect explicitly via the connection manager
  /// when they truly want the transport closed.
  Future<void> close();
}
