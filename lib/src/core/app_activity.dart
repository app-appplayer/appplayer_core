import '../session/app_handle.dart';
import 'app_player_core_service.dart';

/// Trait satisfied by every shell's `AppConfig`-style entry. Exposes only
/// the handle-resolution surface that [AppPlayerCoreServiceActivity]
/// needs — keeps core decoupled from the shell's full model shape.
abstract class HasAppHandle {
  /// One of `'server' | 'bundle' | 'dashboard'`. Selects which core
  /// query to run.
  String get handleKind;

  /// Server config id (server / dashboard inner connection) or
  /// `null` when this entry is a pure bundle.
  String? get serverConfigId;

  /// Bundle id (bundle entry) or `null` for server / dashboard.
  String? get bundleId;

  /// Inner connection ids — only meaningful when `handleKind == 'dashboard'`.
  List<String> get dashboardConnectionIds;

  /// Fallback id used when [serverConfigId] / [bundleId] are missing.
  String get id;
}

/// FR-CORE-ACTIVE-001 — single API for "is this app currently active?".
/// Every shell launcher tile should call this rather than build its own
/// per-tier aggregator.
extension AppPlayerCoreServiceActivity on AppPlayerCoreService {
  bool isAppActive(HasAppHandle app) {
    switch (app.handleKind) {
      case 'server':
        return isServerConnected(app.serverConfigId ?? app.id);
      case 'bundle':
        return isBundleLoaded(app.bundleId ?? app.id);
      case 'dashboard':
        for (final id in app.dashboardConnectionIds) {
          if (isServerConnected(id)) return true;
        }
        return false;
      default:
        return false;
    }
  }

  /// Returns the [AppHandle] used by core for the given launcher entry.
  /// Useful for `closeApp(handle)` calls from a context-menu close action.
  AppHandle handleFor(HasAppHandle app) {
    switch (app.handleKind) {
      case 'server':
        return AppHandle.server(app.serverConfigId ?? app.id);
      case 'bundle':
        return AppHandle.bundle(app.bundleId ?? app.id);
      case 'dashboard':
        // Dashboard handles are managed via `closeDashboard()`; surface
        // the synthetic id so callers can still log / route uniformly.
        return AppHandle.server(app.id);
      default:
        return AppHandle.server(app.id);
    }
  }
}
