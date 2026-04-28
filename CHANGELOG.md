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
