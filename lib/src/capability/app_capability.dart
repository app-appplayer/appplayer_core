/// App capability model + consent seams (FR-CAP).
///
/// Bundles/server apps must request capabilities explicitly; the user grants
/// or denies per-app. See `docs/03_DDD/platform-integration-foundation.md`.
library;

import 'dart:async';

import '../permission/platform_permission_port.dart';
import '../session/app_handle.dart';

/// A capability an app (bundle / server) can request.
enum AppCapability {
  notifications,
  location,
  camera,
  microphone,
  fileRead,
  fileWrite,
  deviceControl,
  backgroundDelivery,
  network,
}

enum ConsentDecision { granted, denied }

/// Maps a capability to the OS permission it also requires, if any
/// (FR-CAP-006 two-tier gate). Capabilities with no OS-permission backing
/// return null — app consent alone gates them.
PlatformPermission? osPermissionFor(AppCapability capability) {
  switch (capability) {
    case AppCapability.notifications:
      return PlatformPermission.notifications;
    case AppCapability.location:
      return PlatformPermission.location;
    case AppCapability.camera:
      return PlatformPermission.camera;
    case AppCapability.microphone:
      return PlatformPermission.microphone;
    case AppCapability.backgroundDelivery:
      return PlatformPermission.backgroundExecution;
    case AppCapability.fileRead:
    case AppCapability.fileWrite:
    case AppCapability.deviceControl:
    case AppCapability.network:
      return null;
  }
}

/// Host-injected consent UI. The core cannot render — the shell shows the
/// prompt and returns the user's decision (FR-CAP-002).
abstract class ConsentPrompt {
  Future<ConsentDecision> request(
    AppHandle app,
    AppCapability capability,
    String reason,
  );
}

/// Persists per-app capability grants (FR-CAP-003). A durable implementation
/// (prefs / secure store) is host-provided; [InMemoryConsentStore] is the
/// test/default.
abstract class ConsentStore {
  Future<ConsentDecision?> read(AppHandle app, AppCapability capability);
  Future<void> write(
    AppHandle app,
    AppCapability capability,
    ConsentDecision decision,
  );
  Future<void> delete(AppHandle app, AppCapability capability);
  Future<Map<AppCapability, ConsentDecision>> readAll(AppHandle app);
}

/// In-memory grant store (session-scoped). Default for tests; hosts inject a
/// durable store for persistence across restarts.
class InMemoryConsentStore implements ConsentStore {
  final Map<AppHandle, Map<AppCapability, ConsentDecision>> _grants = {};

  @override
  Future<ConsentDecision?> read(AppHandle app, AppCapability capability) async =>
      _grants[app]?[capability];

  @override
  Future<void> write(
    AppHandle app,
    AppCapability capability,
    ConsentDecision decision,
  ) async {
    (_grants[app] ??= {})[capability] = decision;
  }

  @override
  Future<void> delete(AppHandle app, AppCapability capability) async {
    _grants[app]?.remove(capability);
  }

  @override
  Future<Map<AppCapability, ConsentDecision>> readAll(AppHandle app) async =>
      Map.unmodifiable(_grants[app] ?? const {});
}
