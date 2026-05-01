## [0.1.2] - 2026-05-01 - Tool dispatcher align with runtime 0.4.3

### Changed
- `ToolDispatcher.call` now returns `Future<dynamic>` (the decoded JSON response) instead of `Future<void>`. Host self-fold removed; the runtime applies spec §3.10 auto-merge against its own state.
- `runtime` parameter dropped from `ToolDispatcher.call` — no longer needed.
- `AppSessionImpl._onToolCall` returns the dispatcher's response so the runtime can fold it.
- Runtime dependency raised to `flutter_mcp_ui_runtime: ^0.4.3` (carries §3.10 auto-merge + §4.4.2 `event` variable + errorBoundary/errorRecovery `event.{error, stack}` fixes).

---

## [0.1.1] - 2026-04-30 - mcp_client 2.0 dependency

### Changed
- Upgraded `mcp_client` constraint to `^2.0.0`. Public API of appplayer_core is unchanged — mcp_client is consumed internally and not re-exported.

---

## [0.1.0] - 2026-04-28 - Initial Release

### Added
- `AppPlayerCoreService` orchestrator owning connection lifecycle, sessions, bundle install pipeline, and tool dispatch.
- Session abstractions — `AppSession`, `DashboardSession`, `AppHandle`.
- Connection observability — `ConnectionInfo`, `ConnectionResult`, `ConnectionState`, `ConnectionHealthMonitor` with `HealthMonitorConfig`.
- Bundle handles and host ports — `BundleRef`, `BundleEntryPoint`, `BundleFetcher`, `InstalledAppBundle`.
- Dashboard bundle composition — `DashboardBundleRef`, `BundleSource`, `SlotDefinition`, `SlotBindingRule`.
- Apps registry — `AppsRegistry` + `RegistryMetadataSink` automatic metadata refresh.
- Tenant model — `TenantContext`, `TenantSource` for multi-tenant variants.
- Host ports — `ServerStorage`, `CredentialVault`, `AppMetadataSink`.
- Observability ports — `Logger`, `MetricsPort`.
- Re-exports from `flutter_mcp_ui_runtime` — `FormFactor`, `FormFactorScope`, `ViewMode`/`ViewModeResolver`, `AppSpacing` / `AppIconSizes` / `AppTypography` / `AppDensity` (and their scale companions), `TrustLevel`, `TrustLevelManager`.
- Re-export of `MCPUIDSLVersion` from `flutter_mcp_ui_core`.
- Active-state extension via `app_activity.dart`.
