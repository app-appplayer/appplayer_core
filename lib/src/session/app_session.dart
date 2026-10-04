import 'package:flutter/widgets.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show IdentityPromoter;
import 'package:mcp_bundle/mcp_bundle.dart' show McpBundle;

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

  /// The bundle manifest, surfaced only for bundle-backed sessions.
  /// Server-backed sessions return `null`. Host shells (Standard chrome,
  /// Pro launcher, etc.) read the declaration regions of the manifest
  /// — `wiring` (lifecycle / domainActions / chat / lifecycleState),
  /// `settings.sections`, `chat.slashCommands`, etc. — directly and map
  /// them onto their own chrome surfaces (wiring and the settings section).
  McpBundle? get bundle;

  /// Builds the Flutter widget tree for this session. Tool call / resource
  /// subscribe / notification routing are wired inside — hosts do not need
  /// to pass callbacks.
  Widget buildWidget({
    required BuildContext context,
    VoidCallback? onExit,
  });

  /// Dashboard rendering entry point. Returns `null` when the
  /// DSL declares no `dashboard` block — the host should fall back to a
  /// default card derived from [metadata]. The returned
  /// widget hosts only the `dashboard.content` subtree and re-evaluates
  /// bindings on `dashboard.refreshInterval`.
  ///
  /// [onOpenApp] is invoked for DSL `navigation:openApp` actions
  /// fired from within the dashboard subtree — hosts use this
  /// to transition the launcher to the full application view.
  Widget? buildDashboardWidget({
    required BuildContext context,
    VoidCallback? onExit,
    void Function(String? appId, String? route)? onOpenApp,
  });

  /// True when the entry that opened this session named a page this app no
  /// longer declares (platform spec 19 §4.3).
  ///
  /// The session renders the app's own initial route in that case. The host
  /// MUST NOT let that pass as success — spec 19 §9.6 requires it to say the
  /// requested page was unavailable, and a home screen that looks identical
  /// to a working entry is how a stale binding hides. Always false for a
  /// session opened without an entry.
  bool get launchRouteMissing;

  /// Wire how this host turns a guest into an identified viewer, and back
  /// (platform spec 19 §5.3).
  ///
  /// Promotion is the **host's** act: the document may ask for it, the origin
  /// re-authorizes, and the app takes no part. So the handlers belong to
  /// whoever owns the sign-in, not to the runtime and not to core — core has
  /// no idea who this viewer would be.
  ///
  /// Registering nothing leaves `identity.promote` / `identity.release`
  /// unsupported, which is the honest answer on a build with no sign-in: a
  /// document that asks gets told it cannot happen here rather than being
  /// shown a prompt that goes nowhere.
  ///
  /// The session is not restarted and its state is not discarded — the
  /// identity is published and bound expressions re-evaluate in place, which
  /// is what §5.3 means by preserving the entry context.
  void registerIdentityPromotion({
    IdentityPromoter? onPromote,
    IdentityPromoter? onRelease,
  });

  /// Unsubscribe resources, destroy the underlying runtime and let go of this
  /// screen's hold on the server connection (if any). The connection closes
  /// only when nothing else holds it — a lent session on the same device keeps
  /// it open (23 §6.1.4).
  Future<void> close();
}
