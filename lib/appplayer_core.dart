/// AppPlayer Core — shared library for MCP server connection,
/// bundle handling, and UI runtime orchestration.
///
/// This barrel exposes the **public stable API** (semver-tracked). Internal
/// wiring (ConnectionManager, RuntimeManager, ToolDispatcher, etc.) is
/// available via `package:appplayer_core/internals.dart` for advanced
/// integrations but is not semver-stable.
library;

// Orchestrator
export 'src/core/app_player_core_service.dart';

// Session abstractions (public handles)
export 'src/session/app_session.dart';
export 'src/session/dashboard_session.dart';
export 'src/session/app_handle.dart';

// Connection observability (values)
export 'src/connection/connection_info.dart';
export 'src/connection/connection_result.dart';
export 'src/connection/connection_state.dart';
export 'src/connection/connection_health_monitor.dart'
    show HealthMonitorConfig;

// Bundle handles / host ports
export 'src/bundle/bundle_ref.dart';
export 'src/bundle/bundle_entry_point.dart';
export 'src/bundle/bundle_fetcher.dart';
export 'src/bundle/installed_app_bundle.dart';

// Dashboard handles
export 'src/dashboard/dashboard_bundle.dart'
    show DashboardBundleRef, BundleSource, SlotDefinition, SlotBindingRule;

// Tenant
export 'src/tenant/tenant_context.dart';
export 'src/tenant/tenant_source.dart';

// Host Ports
export 'src/storage/server_storage.dart';
export 'src/storage/credential_vault.dart';
export 'src/metadata/app_metadata.dart';
export 'src/metadata/app_metadata_sink.dart';

// Apps registry (registered-app list — single source of truth)
export 'src/registry/apps_registry.dart';
export 'src/registry/registry_metadata_sink.dart';

// Active-state extension on AppPlayerCoreService + handle resolver trait.
export 'src/core/app_activity.dart';

// Models
export 'src/model/server_config.dart';
export 'src/model/application_definition.dart';

// Logging / Metrics (observability ports — Core-defined)
export 'src/logging/logger.dart';
export 'src/logging/log_entry.dart';
export 'src/logging/log_buffer.dart';
export 'src/logging/scoped_logger.dart';
export 'src/logging/buffer_logger.dart';
export 'src/metrics/metrics_port.dart';
export 'src/runtime/notification_router.dart' show McpLogMessageHandler;
// MCP logging spec — host passes McpLogLevel to setMcpLoggingLevel().
export 'package:mcp_client/mcp_client.dart' show McpLogLevel;

// Upstream version constant re-export (flutter_mcp_ui_core) — allows hosts
// to display the DSL version without importing the runtime package directly.
export 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    show MCPUIDSLVersion;

// Upstream form-factor + responsive token re-export
// (flutter_mcp_ui_runtime) — allows hosts to consume the FormFactor
// resolver, FormFactorScope override, the four responsive token sets,
// and the TrustLevel permission enum without importing the runtime
// package directly. Preserves the invariant that AppPlayer Standard
// depends only on `appplayer_core`.
export 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show
        FormFactor,
        FormFactorScope,
        ViewMode,
        ViewModeResolver,
        AppSpacing,
        AppSpacingScale,
        AppIconSizes,
        AppIconSizesScale,
        AppTypography,
        AppTypographyScale,
        AppDensity,
        TrustLevel,
        TrustLevelManager;

// Exceptions
export 'src/exceptions.dart';
