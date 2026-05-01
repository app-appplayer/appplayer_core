## [0.1.4] - 2026-05-02 - Field-report logging stack — corrects 0.1.3 wiring

Supersedes the misaligned 0.1.3 release. The logging primitives shipped in 0.1.3 conflated AppPlayer Core's own diagnostic logger with the MCP `notifications/message` log channel; this release re-architects them so a single in-app `LogBuffer` collects both sources, distinguished by `LogEntry.source`, and the MCP logging spec (`notifications/message` + `logging/setLevel`) is wired to its own routing path.

### Changed (breaking — 0.1.3 → 0.1.4)
- `LogEntry` now requires a `source: LogSource` (enum `core` / `mcp`). `level` field is now `McpLogLevel` (RFC 5424 8 levels — verbatim) instead of the 4-level `LogLevel`. Construct via `LogEntry.fromCore(LogLevel)` (4→8 mapping) or `LogEntry.fromMcp({serverId, params})`.
- `LogBuffer.atLeast` parameter changed from `LogLevel` to `McpLogLevel`. Added `withSource(LogSource)` filter.

### Added
- `BufferLogger` — `Logger` adapter that pushes records into a `LogBuffer` as `source=core` entries. Pair with a console adapter inside `CompositeLogger` so a single Core diagnostic call lands in DevTools (development) AND the in-app `LogBuffer` (field report).
- MCP logging spec wiring (MOD-RUNTIME-005a, NFR-OBS-006~007):
  - `NotificationRouter` routes `notifications/message` into a host-provided `McpLogMessageHandler` callback `(serverId, params)`.
  - `AppPlayerCoreService.initialize(... onMcpLogMessage: ...)` parameter.
  - `AppPlayerCoreService.setMcpLoggingLevel(serverId, McpLogLevel)` — sends `logging/setLevel` so the server filters its own emission (server-side filter, spec-canonical).
  - `McpLogMessageHandler` typedef and `McpLogLevel` (re-export from `mcp_client`) in the public barrel.

### Rationale
Two log layers, one destination:
- **Development** uses OS standard log pipelines (host `ConsoleLogger` → `dart:developer.log` → DevTools / Console.app / logcat). Core diagnostics also flow there via `CompositeLogger`.
- **Field reports** require an in-app surface that production users can export when filing an issue. `BufferLogger` (Core diagnostics) and `onMcpLogMessage` (server logs) both feed the same `LogBuffer`, distinguished by `LogEntry.source`.

---

## [0.1.3] - 2026-05-02 - Logging primitives (LogEntry / LogBuffer / ScopedLogger)

### Added
- `LogEntry` — structured record (timestamp, level, message, context, error, stackTrace).
- `LogBuffer` — `ChangeNotifier` ring buffer (default 1000 entries) with scope/level filters. Tier shells (Pro / X / Custom) read this buffer to render in-app log viewers.
- `ScopedLogger` — `Logger` decorator that injects a fixed scope map (e.g. `{serverId, handle}`) into every log call's context, so downstream filters can isolate logs per connection/app.
- `CompositeLogger` — fan-out to multiple inner loggers (typical use: console adapter + LogBuffer adapter side-by-side).

Core internal modules (ConnectionManager / ToolDispatcher / AppSession / NotificationRouter / ResourceSubscriber) are unchanged — composition roots inject a `ScopedLogger` and the existing `_logger.debug(...)` calls automatically carry the scope.

> **Note:** This release misaligned the LogBuffer wiring with the MCP logging spec — see 0.1.4 for the corrected design (LogEntry.source, LogEntry.fromMcp, NotificationRouter `notifications/message` handler, `setMcpLoggingLevel` API).

---

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
