/// AppPlayer Core — advanced integration barrel.
///
/// Exposes internal wiring components (connection/runtime/bundle/dashboard
/// managers and dispatchers) so advanced hosts can construct custom flows
/// that the public [AppSession] abstraction does not cover.
///
/// **No semver guarantee.** Anything exported here may change or be removed
/// across minor versions. Prefer [package:appplayer_core/appplayer_core.dart]
/// whenever possible.
library;

// Connection internals
export 'src/connection/connection_manager.dart';
export 'src/connection/transport_factory.dart';

// Runtime internals
export 'src/runtime/runtime_manager.dart';
export 'src/runtime/application_loader.dart' show ApplicationLoader, PageLoader;
export 'src/runtime/tool_dispatcher.dart';
export 'src/runtime/resource_subscriber.dart';
export 'src/runtime/notification_router.dart';
export 'src/runtime/app_metadata_provider.dart';

// Bundle internals (BundleLoaderAdapter wraps mcp_bundle parsing)
export 'src/bundle/bundle_loader_adapter.dart';
export 'src/bundle/bundle_resolver.dart';
export 'src/bundle/bundle_uri_resolver.dart';
export 'src/bundle/bundle_application_adapter.dart';

// Dashboard internals
export 'src/dashboard/dashboard_bundle_loader.dart'
    show DashboardBundleLoader, HttpBundleFetcher;
export 'src/dashboard/slot_binder.dart';
export 'src/dashboard/summary_view_resolver.dart';
export 'src/dashboard/dashboard_orchestrator.dart';

// Tenant internals
export 'src/tenant/tenant_resolver.dart';
