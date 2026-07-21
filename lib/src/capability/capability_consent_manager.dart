/// Per-app capability consent + enforcement (FR-CAP).
library;

import '../logging/logger.dart';
import '../permission/platform_permission_port.dart';
import '../session/app_handle.dart';
import 'app_capability.dart';

/// Gates app (bundle / server) use of a [AppCapability]: checks the stored
/// grant, prompts on first use, persists the decision, and — for OS-backed
/// capabilities — also requests the platform permission (two-tier gate).
///
/// Trust Level is the coarse ceiling; this consent is the explicit refinement
/// within it. The runtime tool dispatcher calls [ensure] before executing a
/// capability-gated action.
class CapabilityConsentManager {
  CapabilityConsentManager({
    required ConsentStore store,
    required ConsentPrompt prompt,
    PlatformPermissionPort? permissions,
    Logger? logger,
  })  : _store = store,
        _prompt = prompt,
        _permissions = permissions,
        _logger = logger ?? NoopLogger();

  final ConsentStore _store;
  final ConsentPrompt _prompt;
  final PlatformPermissionPort? _permissions;
  final Logger _logger;

  /// Ensure [app] may use [capability]. Prompts once when the decision is
  /// unknown, persists it, and for OS-backed capabilities also requires the
  /// platform permission. Returns whether the capability may be used now.
  Future<bool> ensure(
    AppHandle app,
    AppCapability capability, {
    String? reason,
  }) async {
    var decision = await _store.read(app, capability);

    if (decision == null) {
      decision = await _prompt.request(
        app,
        capability,
        reason ?? _defaultReason(capability),
      );
      await _store.write(app, capability, decision);
      _logger.info('capability.consent.decided', {
        'app': app.toString(),
        'capability': capability.name,
        'decision': decision.name,
      });
    }

    if (decision == ConsentDecision.denied) return false;

    // Two-tier gate (FR-CAP-006): OS-backed capabilities also need the
    // platform permission.
    final osPermission = osPermissionFor(capability);
    final permissions = _permissions;
    if (osPermission != null && permissions != null) {
      final status = await permissions.request(osPermission);
      if (status != PermissionStatus.granted) {
        _logger.warn('capability.consent.os_permission_missing', {
          'app': app.toString(),
          'capability': capability.name,
          'permission': osPermission.name,
          'status': status.name,
        });
        return false;
      }
    }

    return true;
  }

  Future<Set<AppCapability>> grantsOf(AppHandle app) async {
    final all = await _store.readAll(app);
    return {
      for (final e in all.entries)
        if (e.value == ConsentDecision.granted) e.key,
    };
  }

  /// Revoke a previously-granted capability (FR-CAP-005). The next use
  /// re-prompts.
  Future<void> revoke(AppHandle app, AppCapability capability) async {
    await _store.delete(app, capability);
    _logger.info('capability.consent.revoked', {
      'app': app.toString(),
      'capability': capability.name,
    });
  }

  String _defaultReason(AppCapability capability) =>
      'This app requests the "${capability.name}" capability.';
}
