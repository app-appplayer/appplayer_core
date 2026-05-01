import 'dart:async';
import 'dart:ui' show Brightness;

import 'package:flutter/foundation.dart'
    show Listenable, ValueListenable, visibleForTesting;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    hide ApplicationDefinition;
import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;
import 'package:mcp_client/mcp_client.dart' show McpLogLevel;

import '../bundle/bundle_application_adapter.dart';
import '../bundle/bundle_entry_point.dart';
import '../bundle/bundle_fetcher.dart';
import '../bundle/bundle_installer_adapter.dart';
import '../bundle/bundle_loader_adapter.dart';
import '../bundle/bundle_ref.dart';
import '../bundle/bundle_resolver.dart';
import '../bundle/bundle_uri_resolver.dart';
import '../bundle/installed_app_bundle.dart';
import '../connection/connection_health_monitor.dart';
import '../connection/connection_info.dart';
import '../connection/connection_manager.dart';
import '../connection/connection_state.dart';
import '../dashboard/dashboard_bundle.dart';
import '../dashboard/dashboard_bundle_loader.dart';
import '../dashboard/dashboard_orchestrator.dart';
import '../dashboard/slot_binder.dart';
import '../dashboard/summary_view_resolver.dart';
import '../exceptions.dart';
import '../logging/logger.dart';
import '../metadata/app_metadata.dart';
import '../metadata/app_metadata_sink.dart';
import '../metrics/metrics_port.dart';
import '../model/application_definition.dart';
import '../model/server_config.dart';
import '../runtime/app_metadata_provider.dart';
import '../runtime/application_loader.dart';
import '../runtime/notification_router.dart';
import '../runtime/resource_subscriber.dart';
import '../runtime/runtime_manager.dart';
import '../runtime/tool_dispatcher.dart';
import '../session/app_handle.dart';
import '../session/app_session.dart';
import '../session/app_session_impl.dart';
import '../session/dashboard_session.dart';
import '../session/dashboard_session_impl.dart';
import '../storage/credential_vault.dart';
import '../storage/server_storage.dart';
import '../tenant/tenant_context.dart';
import '../tenant/tenant_resolver.dart';
import '../tenant/tenant_source.dart';

/// Top-level entrypoint assembling Connection / Runtime / Session / Dashboard /
/// Tenant layers (MOD-CORE-001, FR-CORE-001~008).
///
/// Hosts receive [AppSession] / [DashboardSession] from the open* methods and
/// never touch [MCPUIRuntime] directly.
class AppPlayerCoreService {
  AppPlayerCoreService() : _testConnector = null;

  /// Test-only constructor that injects a mock [ClientConnector]. Kept out of
  /// the public [initialize] signature to prevent leaking a transport seam
  /// into production APIs (NFR-API-005).
  @visibleForTesting
  AppPlayerCoreService.forTesting({required ClientConnector connector})
      : _testConnector = connector;

  final ClientConnector? _testConnector;

  // Wired during [initialize].
  late final ConnectionManager _conn;
  late final ConnectionHealthMonitor _health;
  late final RuntimeManager _runtime;
  late final ApplicationLoader _appLoader;
  late final ToolDispatcher _toolDispatcher;
  late final ResourceSubscriber _resourceSub;
  late final NotificationRouter _notifRouter;
  late final DashboardOrchestrator _dashboard;
  late final TenantResolver _tenant;
  late final ServerStorage _storage;
  late final Logger _logger;
  late final MetricsPort _metrics;
  late final CredentialVault _credentialVault;
  late final BundleLoaderAdapter _bundleLoader;
  late final BundleResolver _bundleResolver;
  late final BundleApplicationAdapter _bundleAdapter;
  late final BundleInstallerAdapter _bundleInstaller;
  late final AppMetadataProvider _metadataProvider;
  late final String _bundleInstallRoot;

  bool _initialized = false;

  // Dashboard handle tracked so close() can be idempotent.
  DashboardSession? _activeDashboardSession;

  /// Last-known `AppMetadata` per handle. Populated on the first
  /// `openAppFromServer` / `openAppFromBundle` that performs a metadata
  /// fetch and reused on subsequent opens that hit the "runtime already
  /// initialised" path (connection and runtime reuse per serverId). Without
  /// this, the second [AppSession] would carry `metadata == null` and
  /// the launcher would fall back to the default icon and raw serverId
  /// label instead of the cached name/icon.
  final Map<AppHandle, AppMetadata> _metadataCache = {};

  /// Host-injected brightness feed forwarded to the runtime so `system`
  /// theme mode resolves against the embedder's light/dark choice rather
  /// than the OS directly.
  ValueListenable<Brightness>? _hostBrightness;

  ValueListenable<Brightness>? get hostBrightness => _hostBrightness;

  /// Optional handler invoked when an MCP server emits
  /// `notifications/message` (logging spec). Hosts typically push the
  /// payload into a `LogBuffer` so the in-app log viewer can render it.
  /// Receives `(serverId, params)` where `params` carries the raw MCP
  /// `{level, logger?, data}` shape.
  McpLogMessageHandler? _onMcpLogMessage;

  /// FR-CORE-001
  Future<void> initialize({
    required ServerStorage storage,
    required String bundleInstallRoot,
    TenantSource? tenantSource,
    Logger? logger,
    MetricsPort? metrics,
    BundleFetcher? bundleFetcher,
    AppMetadataSink? appMetadataSink,
    CredentialVault? credentialVault,
    HealthMonitorConfig? healthConfig,
    ValueListenable<Brightness>? hostBrightness,
    McpLogMessageHandler? onMcpLogMessage,
  }) async {
    if (_initialized) {
      throw StateError('AppPlayerCoreService already initialized');
    }

    _logger = logger ?? NoopLogger();
    _metrics = metrics ?? const NoopMetricsPort();
    _credentialVault = credentialVault ?? const NoopCredentialVault();
    _storage = storage;
    _bundleInstallRoot = bundleInstallRoot;
    _conn = ConnectionManager(logger: _logger, connector: _testConnector);
    _runtime = RuntimeManager(logger: _logger);
    _appLoader = ApplicationLoader(logger: _logger);
    _toolDispatcher = ToolDispatcher(logger: _logger);
    _resourceSub = ResourceSubscriber(logger: _logger);
    _notifRouter = NotificationRouter(logger: _logger);
    _tenant = TenantResolver(source: tenantSource, logger: _logger);
    _bundleLoader = BundleLoaderAdapter(
      fetcher: bundleFetcher,
      logger: _logger,
      metrics: _metrics,
      installRoot: bundleInstallRoot,
    );
    _bundleResolver = const BundleResolver();
    _bundleAdapter = BundleApplicationAdapter(logger: _logger);
    _bundleInstaller = BundleInstallerAdapter(
      installRoot: bundleInstallRoot,
      logger: _logger,
    );
    _metadataProvider = AppMetadataProvider(
      sink: appMetadataSink,
      logger: _logger,
    );
    _hostBrightness = hostBrightness;
    _onMcpLogMessage = onMcpLogMessage;

    _dashboard = DashboardOrchestrator(
      conn: _conn,
      runtime: _runtime,
      bundleLoader: DashboardBundleLoader(
        conn: _conn,
        // Dashboard marketUrl fetching is P2 scope and uses a distinct JSON
        // fetcher contract. Dashboard currently supports inline / aggregator /
        // synthesized sources — marketUrl requires a host-provided
        // HttpBundleFetcher which can be wired via internals barrel when
        // needed.
        logger: _logger,
      ),
      binder: SlotBinder(logger: _logger),
      summaryResolver: SummaryViewResolver(logger: _logger),
      resourceSub: _resourceSub,
      notifRouter: _notifRouter,
      storage: _storage,
      logger: _logger,
    );

    _health = ConnectionHealthMonitor(
      conn: _conn,
      config: healthConfig,
      logger: _logger,
    );
    _health.startMonitoring();

    _initialized = true;
    _logger.info('AppPlayerCoreService initialized');
  }

  void _assertReady() {
    if (!_initialized) {
      throw StateError('AppPlayerCoreService not initialized');
    }
  }

  // Server CRUD (FR-STOR passthrough).
  Future<List<ServerConfig>> listServers() {
    _assertReady();
    return _storage.getServers();
  }

  Future<void> saveServer(ServerConfig server) {
    _assertReady();
    return _storage.saveServer(server);
  }

  /// Fetches a single [ServerConfig] by id (FR-STOR passthrough).
  /// Returns `null` when no entry matches.
  Future<ServerConfig?> getServer(String id) {
    _assertReady();
    return _storage.getById(id);
  }

  Future<void> deleteServer(String id) {
    _assertReady();
    return _storage.deleteServer(id);
  }

  /// MCP logging spec — request the server identified by [serverId] to
  /// emit only messages at or above [level] via `notifications/message`.
  /// Returns `false` when there is no active connection for [serverId].
  Future<bool> setMcpLoggingLevel(String serverId, McpLogLevel level) async {
    _assertReady();
    final client = _conn.getConnection(serverId)?.client;
    if (client == null) return false;
    await client.setLoggingLevel(level);
    return true;
  }

  /// FR-CORE-002 — Online path (MCP server serves `ui://` application).
  ///
  /// [trustLevel] gates which `client.*` actions the runtime will
  /// execute. The launcher chooses a level per-app (default `basic`).
  /// See `flutter_mcp_ui_runtime/TrustLevel` for the hierarchy.
  Future<AppSession> openAppFromServer(
    String serverId, {
    TrustLevel trustLevel = TrustLevel.basic,
  }) async {
    _assertReady();
    return _withTenantGuard(
      serverId: serverId,
      operation: () => _openFromServerImpl(serverId, trustLevel),
    );
  }

  Future<AppSession> _openFromServerImpl(
      String serverId, TrustLevel trustLevel) async {
    final server = await _storage.getById(serverId);
    if (server == null) {
      throw ServerNotFoundException(serverId);
    }

    final result = await _conn.connect(server);
    if (!result.success || result.connection?.client == null) {
      throw ConnectionFailedException(
        serverId,
        result.error ?? 'Unknown connection failure',
      );
    }
    final client = result.connection!.client!;

    await _storage.updateLastConnected(serverId, DateTime.now());

    final handle = AppHandle.server(serverId);
    final runtime = _runtime.getOrCreateRuntime(handle);
    AppMetadata? metadata;
    if (!runtime.isInitialized) {
      metadata = await _metadataProvider.fetchFromServer(client, serverId);
      await _metadataProvider.publish(metadata);
      if (metadata != null) {
        _metadataCache[handle] = metadata;
      }

      final definition = await _appLoader.load(client);
      await runtime.initialize(
        definition,
        pageLoader: _appLoader.pageLoaderFor(client),
      );
      runtime.setTrustLevel(trustLevel);
      _notifRouter.register(
        client: client,
        runtime: runtime,
        serverId: serverId,
        onMcpLogMessage: _onMcpLogMessage,
      );
    } else {
      // Reused runtime — honour the caller's trust level in case the
      // launcher bumped the app's grant between opens.
      runtime.setTrustLevel(trustLevel);
      // Runtime + connection reused from a prior open — surface the last
      // known metadata so the launcher still renders icon / name tiles
      // without a redundant ui://app/info re-fetch.
      metadata = _metadataCache[handle];
    }

    return AppSessionImpl(
      handle: handle,
      runtime: runtime,
      conn: _conn,
      runtimeManager: _runtime,
      toolDispatcher: _toolDispatcher,
      resourceSubscriber: _resourceSub,
      logger: _logger,
      metadata: metadata,
      hostBrightness: _hostBrightness,
    );
  }

  /// FR-CORE-003 — Local Bundle path (`McpBundle` file / inline JSON).
  Future<AppSession> openAppFromBundle(
    BundleRef bundleRef, {
    TrustLevel trustLevel = TrustLevel.basic,
  }) async {
    _assertReady();
    final bundle = await _bundleLoader.load(bundleRef);
    final bundleId = bundle.manifest.id;

    return _withTenantGuard(
      bundleId: bundleId,
      operation: () => _openFromBundleImpl(bundle, trustLevel),
    );
  }

  Future<AppSession> _openFromBundleImpl(
      McpBundle bundle, TrustLevel trustLevel) async {
    final bundleId = bundle.manifest.id;
    _bundleResolver.assertApplicationType(bundle);
    final entry = _bundleResolver.resolveEntry(bundle);
    _bundleResolver.assertUiEntry(entry, bundleId: bundleId);

    final uriResolver = BundleUriResolver(
      assets: bundle.assets,
      logger: _logger,
    );

    final metadata = _metadataProvider.fromBundle(bundle, uriResolver);
    await _metadataProvider.publish(metadata);

    final ApplicationDefinition definition;
    try {
      definition =
          await _bundleAdapter.adapt(bundle, entry, uriResolver: uriResolver);
    } on BundleAdaptException {
      rethrow;
    } catch (e, st) {
      _logger.logError('bundle.adapt.fail', e, st, {'bundleId': bundleId});
      throw BundleAdaptException(
        bundleId: bundleId,
        reason: BundleAdaptReason.unknown,
        cause: e,
      );
    }

    final handle = AppHandle.bundle(bundleId);
    _metadataCache[handle] = metadata;
    final runtime = _runtime.getOrCreateRuntime(handle);
    if (!runtime.isInitialized) {
      await runtime.initialize(
        definition.json,
        pageLoader: definition.pageLoader,
      );
    }
    runtime.setTrustLevel(trustLevel);

    return AppSessionImpl(
      handle: handle,
      runtime: runtime,
      conn: _conn,
      runtimeManager: _runtime,
      toolDispatcher: _toolDispatcher,
      resourceSubscriber: _resourceSub,
      logger: _logger,
      metadata: metadata,
      hostBrightness: _hostBrightness,
    );
  }

  /// FR-CORE-008 — terminate a session by handle.
  ///
  /// The client always releases its connection on close, regardless of
  /// transport. Server lifecycle is the server's concern: a stdio server
  /// sees stdin EOF and exits (stdio has no "wait for next client"
  /// semantics); an HTTP-family server simply resumes waiting for the
  /// next connection. The client never forces the peer to terminate.
  Future<void> closeApp(AppHandle handle) async {
    _assertReady();
    final runtime = _runtime.getRuntime(handle);
    if (runtime != null && handle.source == AppSource.server) {
      final client = _conn.connections[handle.key]?.client;
      if (client != null) {
        await _resourceSub.unsubscribeAllFor(
          client: client,
          runtime: runtime,
          ownerKey: handle.key,
        );
      }
    }
    await _runtime.removeRuntime(handle);
    _metadataCache.remove(handle);

    if (handle.source == AppSource.server) {
      await _conn.disconnect(handle.key);
    }
  }

  // Bundle install lifecycle (FR-INSTALL-001~005).
  Future<InstalledAppBundle> installBundleFromFile(String filePath) {
    _assertReady();
    return _bundleInstaller.installFile(filePath);
  }

  Future<InstalledAppBundle> installBundleFromDirectory(String mbdPath) {
    _assertReady();
    return _bundleInstaller.installDirectory(mbdPath);
  }

  Future<InstalledAppBundle> installBundleFromUrl(Uri url) {
    _assertReady();
    return _bundleInstaller.installUrl(url);
  }

  Future<void> uninstallBundle(String bundleId) {
    _assertReady();
    return _bundleInstaller.uninstall(bundleId);
  }

  Future<List<InstalledAppBundle>> listInstalledBundles() {
    _assertReady();
    return _bundleInstaller.list();
  }

  /// Absolute path where installed bundles are stored.
  String get bundleInstallRoot {
    _assertReady();
    return _bundleInstallRoot;
  }

  // Bundle access (exposes MOD-BUNDLE for advanced integrations).
  Future<McpBundle> loadBundle(BundleRef ref) {
    _assertReady();
    return _bundleLoader.load(ref);
  }

  BundleEntryPoint resolveBundleEntry(McpBundle bundle) {
    _assertReady();
    return _bundleResolver.resolveEntry(bundle);
  }

  /// FR-CORE-004
  Future<DashboardSession> openDashboard(
    DashboardBundleRef bundle,
    List<String> deviceIds,
  ) async {
    _assertReady();
    final runtime = await _withTenantGuard(
      bundleId: bundle.bundleId,
      serverIds: deviceIds,
      operation: () => _dashboard.open(bundle, deviceIds),
    );
    final session = DashboardSessionImpl(
      handle: AppHandle.bundle(bundle.bundleId),
      runtime: runtime,
      orchestrator: _dashboard,
      logger: _logger,
    );
    _activeDashboardSession = session;
    return session;
  }

  /// FR-CORE-007 — centralised tenant allowlist gate.
  Future<T> _withTenantGuard<T>({
    String? serverId,
    List<String>? serverIds,
    String? bundleId,
    required Future<T> Function() operation,
  }) async {
    if (serverId != null) {
      _tenant.assertAllowedServer(serverId);
    }
    if (serverIds != null) {
      for (final id in serverIds) {
        _tenant.assertAllowedServer(id);
      }
    }
    if (bundleId != null) {
      _tenant.assertAllowedBundle(bundleId);
    }
    return operation();
  }

  Future<void> closeDashboard() async {
    _assertReady();
    final session = _activeDashboardSession;
    _activeDashboardSession = null;
    if (session != null) {
      await session.close();
    } else {
      await _dashboard.close();
    }
  }

  /// FR-CORE-005
  Future<TenantContext> applyTenant(String appCode) {
    _assertReady();
    return _tenant.apply(appCode);
  }

  Future<void> clearTenant() async {
    _assertReady();
    _tenant.clear();
  }

  TenantContext? get currentTenant => _tenant.current;

  // Observability passthrough.
  Map<String, ConnectionInfo> get connections => _conn.connections;

  /// Notifier that fires whenever connection or runtime lifecycle state
  /// changes — launcher UI listens to this to refresh per-app badges
  /// ("connected" dot on the app icon) without polling.
  Listenable get lifecycleListenable =>
      Listenable.merge(<Listenable>[_conn, _runtime]);

  /// True when a stdio / HTTP connection for [serverId] is live
  /// (`ConnectionState.connected`). Used by the launcher to paint the
  /// "connected" dot on server-type and dashboard-type tiles.
  bool isServerConnected(String serverId) {
    final info = _conn.connections[serverId];
    return info != null && info.state == ConnectionState.connected;
  }

  /// True when a bundle's runtime is currently loaded in the runtime
  /// cache. Bundle apps don't maintain a network connection, so the
  /// cached runtime is the equivalent "is this app active?" signal.
  bool isBundleLoaded(String bundleId) =>
      _runtime.hasRuntime(AppHandle.bundle(bundleId));

  /// Exposed for transport configs that need to read secrets when building
  /// connection options. Callers must not cache returned values.
  CredentialVault get credentialVault {
    _assertReady();
    return _credentialVault;
  }

  //
  // Internal wiring — exposed only through `appplayer_core/internals.dart`.
  // Direct use couples callers to semver-unstable surfaces.
  //

  @visibleForTesting
  ConnectionManager get connectionManagerForInternals {
    _assertReady();
    return _conn;
  }

  @visibleForTesting
  RuntimeManager get runtimeManagerForInternals {
    _assertReady();
    return _runtime;
  }

  @visibleForTesting
  ToolDispatcher get toolDispatcherForInternals {
    _assertReady();
    return _toolDispatcher;
  }

  @visibleForTesting
  ResourceSubscriber get resourceSubscriberForInternals {
    _assertReady();
    return _resourceSub;
  }

  /// FR-CORE-006
  Future<void> dispose() async {
    if (!_initialized) return;
    _health.stopMonitoring();
    await _dashboard.close();
    _activeDashboardSession = null;
    await _runtime.removeAllRuntimes();
    await _conn.disconnectAll();
    _metadataCache.clear();
    _initialized = false;
    _logger.info('AppPlayerCoreService disposed');
  }
}
