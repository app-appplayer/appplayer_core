import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' show Brightness;

import 'composition_host_vendored.dart';
import 'package:flutter/foundation.dart'
    show Listenable, ValueListenable, kIsWeb, visibleForTesting;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary, Widget;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    hide ApplicationDefinition;
import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;
import 'package:mcp_client/mcp_client.dart' show McpLogLevel;

import 'package:brain_kernel/brain_kernel.dart'
    show
        BundleSessionBridge,
        DispatchSession,
        InMemoryKvStoragePort,
        KernelApp,
        KernelClientConnection,
        clientTools,
        standardTools;
// `McpClientKernelHost` (the outbound mcp_client surface the `mcp.*`
// tools drive) and the `connectExtension` seam helper live
// outside the main barrel.
import 'package:brain_kernel/mcp_host.dart'
    show ExtensionTransportConnect, McpClientKernelHost, connectExtension;
import 'package:mcp_client/mcp_client.dart' show Client, ClientTransport;
import '../bundle/bundle_application_adapter.dart';
import '../js/atom_category.dart';
import '../js/atoms/agent_atom.dart';
import '../js/atoms/bundle_atom.dart';
import '../js/atoms/mcp_atom.dart';
import '../js/js_tool_runtime.dart';
import '../settings/settings_store.dart';
import '../bundle/bundle_entry_point.dart';
import '../bundle/bundle_fetcher.dart';
import '../bundle/bundle_installer_adapter.dart';
import '../bundle/bundle_loader_adapter.dart';
import '../bundle/bundle_ref.dart';
import '../bundle/bundle_resolver.dart';
import '../bundle/bundle_uri_resolver.dart';
import '../bundle/installed_app_bundle.dart';
import '../background/background_execution_port.dart';
import '../background/background_policy.dart';
import '../capability/app_capability.dart';
import '../capability/capability_consent_manager.dart';
import '../connection/connection_continuity.dart';
import '../connection/connection_health_monitor.dart';
import '../connection/connection_info.dart';
import '../connection/connection_manager.dart';
import '../connection/connection_state.dart';
import '../debug/debug_capture.dart';
import '../debug/debug_mcp_host.dart';
import '../lifecycle/lifecycle_coordinator.dart';
import '../notification/notification_port.dart';
import '../permission/platform_permission_port.dart';
import '../platform_impl/platform_ports.dart';
import '../schedule/job_scheduler.dart';
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

/// Internal wire state for per-session JS tools — held by `AppSessionImpl`
/// so `close()` can tear down the isolate + unregister dispatcher entries.
class _JsToolWireState {
  _JsToolWireState({required this.runtime, required this.toolNames});
  final JsToolRuntime runtime;
  final List<String> toolNames;
}

/// MCP Serving 1.0 — well-known resource URI carrying the whole bundle
/// document (manifest metadata + sections) for `resources/read`. Reuses the
/// existing `bundle://` scheme; no new scheme.
const String _bundleDocumentUri = 'bundle://manifest.json';

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
  late final SettingsStore _settingsStore;

  // Platform integration foundation (FR-PLATFORM). Constructed in
  // `initialize`; NoOp ports keep pure-Dart hosts working when the shell
  // injects nothing.
  late final BackgroundExecutionPort _background;
  late final PlatformPermissionPort _permissions;
  late final AppNotificationPort _notifications;
  late final ConnectionContinuity _continuity;
  late final JobScheduler _scheduler;
  late final LifecycleCoordinator _lifecycle;
  CapabilityConsentManager? _consent;
  KernelApp? _kernel;
  BundleSessionBridge? _bridge;
  final Map<String, DispatchSession> _sessions =
      <String, DispatchSession>{};

  // Debug MCP surface (FR-DEBUG). Desktop-only, settings-gated — created
  // in [initialize] only when `enableDebugMcp` is set AND the platform is
  // desktop. Null otherwise, in which case [debugCaptureWrap] is a
  // pass-through and [debugCaptureKey] is null.
  DebugSurface? _debugSurface;
  DebugMcpHost? _debugMcpHost;

  bool _initialized = false;

  /// Global key of the debug capture `RepaintBoundary`, or null when the
  /// Debug MCP host is not active. Hosts wrap their root with
  /// [debugCaptureWrap]; the key is exposed for advanced integrations.
  GlobalKey? get debugCaptureKey => _debugSurface?.captureKey;

  /// Wrap [child] in the debug capture `RepaintBoundary` when the Debug
  /// MCP host is active; otherwise return [child] unchanged. Hosts call
  /// this from their root `MaterialApp` builder so the capture / tap /
  /// tree primitives have a stable render boundary.
  Widget debugCaptureWrap(Widget child) {
    final key = _debugSurface?.captureKey;
    if (key == null) return child;
    return RepaintBoundary(key: key, child: child);
  }

  /// Test-only — whether brain_kernel boot succeeded. Production code
  /// goes through the public surface (open* / setActiveSession /
  /// dispose); only regression suites inspect this directly.
  @visibleForTesting
  bool get isKernelBooted => _kernel != null;

  /// Connect to an external MCP server (e.g. an embedded board) over a
  /// host-supplied **extension transport** (serial / usb / ble / tcp / ws),
  /// injected through the kernel seam (`McpClientKernelHost.connectWith`).
  ///
  /// The transport is built outside the core (e.g. by `mcp_bridge`, the opt-in
  /// FFI home) and must already be opened; appplayer_core itself stays free of
  /// the transport's platform / FFI dependencies — the calling app owns those.
  /// Returns a connection whose `callTool` / `readResource` / `listTools`
  /// reach the remote server (e.g. `led.set`, `ui://app`).
  ///
  /// The seam is resolved off the abstract `KernelClientHost` via the
  /// canonical [connectExtension] helper — no concrete
  /// client-host reference is held.
  Future<KernelClientConnection> connectExtensionTransport({
    required String id,
    required ClientTransport transport,
  }) =>
      connectExtension(_kernel?.clientHost, id: id, transport: transport);

  /// Make a connection this host ALREADY holds usable as a composition
  /// origin, under [id] — one device, one connection.
  ///
  /// A device opened from the launcher lives in [connections]; a `view` that
  /// names the same device must ride that link rather than dial its own. Most
  /// embedded boards serve a single peer, so a second dial is refused and the
  /// composed tile fails on a device that is plainly working. Where a second
  /// link is allowed it still splits subscriptions and health tracking in two.
  ///
  /// The adopted client keeps its original owner: closing the origin
  /// deregisters it, it does not disconnect the user's app. Ending a device
  /// connection stays an explicit user action.
  Future<KernelClientConnection> adoptConnectionAsOrigin({
    required String id,
    required Client client,
  }) async {
    final clientHost = _kernel?.clientHost;
    if (clientHost is! ExtensionTransportConnect) {
      throw StateError(
        'client host does not support adopting a host-held connection '
        '(not an ExtensionTransportConnect)',
      );
    }
    return (clientHost as ExtensionTransportConnect)
        .adoptClient(id: id, client: client);
  }

  /// Open the saved device [id] as a composition origin — one device, one
  /// connection.
  ///
  /// Runs through the same [ConnectionManager] the launcher uses, so the link
  /// this creates is the one a later standalone open finds, and a device the
  /// user already opened is reused rather than dialled again. Opening origins
  /// on a private stack is what made a device reachable from one screen and
  /// refused from the other: most of these boards serve a single peer.
  ///
  /// Throws when the id is not a saved device or the device cannot be reached.
  Future<KernelClientConnection> openSavedDeviceAsOrigin(String id) async {
    _assertReady();
    final held = _conn.connections[id]?.client;
    if (held != null && held.isConnected) {
      return adoptConnectionAsOrigin(id: id, client: held);
    }
    final saved = await getServer(id);
    if (saved == null) {
      throw StateError('origin "$id" is not a known device');
    }
    final result = await _conn.connect(saved);
    final client = result.connection?.client;
    if (!result.success || client == null) {
      throw StateError('could not reach origin "$id"'
          '${result.error == null ? '' : ' — ${result.error}'}');
    }
    return adoptConnectionAsOrigin(id: id, client: client);
  }

  /// Register additional in-process capability tools after boot — e.g. a
  /// desktop io / device tool-pack (`io.*`). Host-injected and opt-in: the
  /// core depends on no capability package, so platform-specific adapters
  /// (e.g. `dart:io` process execution) stay in the host layer. The tools
  /// share the same in-process dispatcher as the standard `bk.*` / `mcp.*`
  /// surface, so agents call them identically. Additive — safe to call more
  /// than once.
  void registerCapabilityTools(
    Map<String, Future<Object?> Function(Map<String, dynamic>)> tools,
  ) {
    _assertReady();
    final adapted =
        <String, Future<dynamic> Function(Map<String, dynamic>)>{};
    for (final entry in tools.entries) {
      adapted[entry.key] =
          (Map<String, dynamic> args) async => entry.value(args);
    }
    _toolDispatcher.registerInProcessTools(adapted);
  }

  /// Host-registered `client.mcpStream` sources (scheme → opener). A bundle's
  /// live server-pushed channel (e.g. `ble://scan`) resolves through these.
  final List<
      ({
        String scheme,
        Stream<dynamic> Function(String uri, Map<String, dynamic> params) open
      })> _streamSources = [];

  /// Resolves a `view`/route `DefinitionSource` that names an origin
  /// (MCP UI DSL v1.4 §1.9, Composition Profile). Set by [registerDefinitionResolver].
  Future<Map<String, dynamic>> Function(
      String ref, Map<String, dynamic> origin)? _definitionResolver;

  /// Runs a tool against a named origin — the acting half of the Composition
  /// Profile. Set by [useKernelDefinitionResolver] alongside the resolver,
  /// because a host that can render another origin's UI but not act on it
  /// ships a screen that looks finished and does nothing.
  Future<dynamic> Function(
      Map<String, dynamic> origin,
      String tool,
      Map<String, dynamic> params)? _originToolCaller;

  /// Watches a resource on a named origin — the live half. Set alongside the
  /// tool caller, because a composed screen that can act on a device but never
  /// track it shows a reading's label and no value.
  Future<void Function()> Function(
    Map<String, dynamic> origin,
    String uri,
    void Function(dynamic contents) onUpdate,
  )? _originResourceWatcher;

  /// One-shot read on a named origin. Separate from the watcher so a view that
  /// only reads does not leave a device streaming to it.
  Future<Object?> Function(Map<String, dynamic> origin, String uri)?
      _originResourceReader;

  /// The registered composition resolver, or `null` when this host does not
  /// claim the Composition Profile. Exposed so a host (or its tests) can
  /// verify its own claim and drive the exact production resolution path
  /// rather than a parallel one.
  Future<Map<String, dynamic>> Function(String ref, Map<String, dynamic> origin)?
      get definitionResolver => _definitionResolver;

  /// Register the resolver that backs multi-origin composition — one bundle
  /// rendering definitions served by several MCP servers (spec v1.4 §6.11).
  ///
  /// Registering it is how this host CLAIMS the Composition Profile. Without
  /// it `view` fails closed and renders its `fallback` rather than resolving a
  /// foreign `$ref` against the app's own server (§18.7.3) — which would put
  /// one device's UI under another's identity.
  ///
  /// [resolve] receives the resource uri and the `Origin` map (`{}` when the
  /// source named no origin). It MUST throw on an unknown origin or a failed
  /// read; returning a substitute is exactly the confusion the spec forbids.
  ///
  /// The default wiring is [useKernelDefinitionResolver], which reads through
  /// the kernel's outbound `mcp.*` surface. It is opt-in so a host with no
  /// outbound client stays non-composing.
  void registerDefinitionResolver(
    Future<Map<String, dynamic>> Function(String ref, Map<String, dynamic> origin)
        resolve,
  ) {
    _definitionResolver = resolve;
  }

  /// Claim the Composition Profile using the kernel's own `mcp.*` tools.
  ///
  /// This is the canonical wiring: platform spec `06-tool-registry.md` already
  /// declares "the app/bundle drives `mcp.*` directly and fetches a resource
  /// (e.g. a dashboard UI)" as the default path, and those tools are already on
  /// this host's in-process dispatcher. So composition needs no new transport,
  /// no new connection registry, and no manifest field — only a reader.
  ///
  /// An `Origin` of `{connection: id}` reads through that connection;
  /// an empty origin reads the app's own server via the session's page loader,
  /// which the caller supplies as [readOwn].
  /// [openOrigin] — host hook that opens a named origin on demand.
  ///
  /// A `view` names a connection; it does not open one. Registering a device
  /// does not hold a connection open either, and holding one would be wrong:
  /// a board serving MCP over TCP is often **single-peer**, so a permanent
  /// connection per registered device makes the last one to connect reset the
  /// others (measured on the bench as `Connection reset by peer`). So the
  /// origin is opened when a `view` first needs it and the device lifecycle
  /// stays with the host, which is the only party that knows the transport.
  ///
  /// Called only when the origin is not already connected. Throwing (or
  /// leaving the origin unconnected) makes that one `view` render its
  /// `fallback`; siblings are unaffected.
  void useKernelDefinitionResolver({
    Future<Map<String, dynamic>> Function(String uri)? readOwn,
    Future<void> Function(String connectionId)? openOrigin,
  }) {
    // Built by the `composition_host` recipe rather than here. The wiring is
    // not AppPlayer-specific — any host with a kernel client host claims the
    // profile the same way — and a second copy is how one host ends up with
    // acting or watching quietly missing while the other has it.
    final hooks = buildCompositionHooks(
      call: _toolDispatcher.callInProcess,
      clientHost: () => _kernel?.clientHost,
      openOrigin: openOrigin,
      readOwn: readOwn,
    );
    registerDefinitionResolver(hooks.resolveDefinition);
    _originToolCaller = hooks.callTool;
    _originResourceWatcher = hooks.watchResource;
    _originResourceReader = hooks.readResource;
  }

  /// Apply the registered definition resolver to a freshly-initialized runtime.
  ///
  /// Logged either way. A host that never claimed the Composition Profile and a
  /// host that claimed it but failed to carry it into this runtime look
  /// identical from the app: `view` renders its fallback and says the profile
  /// is not implemented, with nothing to say which of the two happened.
  void _applyDefinitionResolver(MCPUIRuntime runtime) {
    final call = _originToolCaller;
    if (call != null) runtime.registerOriginToolCaller(call);
    final watch = _originResourceWatcher;
    if (watch != null) runtime.registerOriginResourceWatcher(watch);
    final read = _originResourceReader;
    if (read != null) runtime.registerOriginResourceReader(read);
    final resolve = _definitionResolver;
    if (resolve != null) {
      runtime.registerDefinitionResolver(resolve);
      _logger.info('composition profile applied to runtime');
    } else {
      _logger.info('composition profile NOT claimed by this host — '
          '`view` will fall back');
    }
  }

  /// Register a `client.mcpStream` source — e.g. a BLE scan hub for `ble://`.
  /// Applied to every app/bundle runtime after it initializes, so DSL bundles
  /// can bind live server-pushed data. Host-injected and opt-in: the core
  /// carries no radio/transport dep, mirroring [registerCapabilityTools].
  /// Additive — safe to call more than once (per-scheme, last wins in the host
  /// runtime resolver). Registrations made before boot apply to every runtime;
  /// calling after a runtime exists applies to runtimes created afterwards.
  void registerStreamSource(
    String scheme,
    Stream<dynamic> Function(String uri, Map<String, dynamic> params) open,
  ) {
    _streamSources.add((scheme: scheme, open: open));
  }

  /// Apply every registered stream source to a freshly-initialized runtime
  /// (the runtime API requires initialization first).
  void _applyStreamSources(MCPUIRuntime runtime) {
    for (final s in _streamSources) {
      runtime.registerStreamSource(s.scheme, s.open);
    }
  }

  /// Test-only — whether the bundle session bridge is booted. Pairs
  /// with [isKernelBooted] for the wiring regression suite.
  @visibleForTesting
  bool get isBridgeBooted => _bridge != null;

  /// Test-only — open session count (per-bundle map size). Increments
  /// on activate, decrements on close.
  @visibleForTesting
  int get openSessionCount => _sessions.length;

  /// Test-only — in-process tool names registered onto the dispatcher.
  /// `bk.fact.write` ... `bk.knowledge.query` should appear once
  /// `KernelApp.boot` + `standardTools(app)` register succeeds.
  @visibleForTesting
  List<String> get inProcessToolNames => _toolDispatcher.inProcessToolNames;

  /// MCP Serving 1.0 — URIs currently served over the bridge, e.g.
  /// `bundle://manifest.json` for an open bundle. Host/test introspection.
  List<String> get servedResources => _bridge?.listResources() ?? const [];

  /// MCP Serving 1.0 — read a served resource by URI, delegating to the
  /// bridge. Returns the bundle document for `bundle://manifest.json`, or
  /// null when no bundle is open / the URI is unknown.
  Future<Object?> readServedResource(String uri) async =>
      _bridge?.readResource(uri);

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

  /// Whether this service installed the runtime log bridge, so `dispose`
  /// removes only its own and never a host's or another instance's.
  bool _runtimeLogInstalled = false;

  /// FR-CORE-001
  ///
  /// [workspaceId] — the workspace identifier passed to brain_kernel's
  /// `FlowBrainWiring`. Hosts pick their own value (for example
  /// `appplayer.standard` / `appplayer.pro` / etc.). Defaults to
  /// `appplayer` when unspecified.
  /// Receives the UI DSL runtime's own diagnostics.
  ///
  /// The runtime talks to `dart:developer`, which reaches DevTools and stops.
  /// Some of what it says is addressed to whoever wrote the document — a
  /// theme role declared and dropped, an asset reference nothing could
  /// resolve — and that person is looking at the app. A host that passes this
  /// gets those records and can put them where its own logs go.
  ///
  /// `stdout` is not an alternative: on a stdio MCP connection it carries the
  /// protocol.
  Future<void> initialize({
    RuntimeLogHandler? onRuntimeLog,
    required ServerStorage storage,
    required String bundleInstallRoot,
    BundleInstallStore? bundleInstallStore,
    String workspaceId = 'appplayer',
    TenantSource? tenantSource,
    Logger? logger,
    MetricsPort? metrics,
    BundleFetcher? bundleFetcher,
    AppMetadataSink? appMetadataSink,
    CredentialVault? credentialVault,
    HealthMonitorConfig? healthConfig,
    ValueListenable<Brightness>? hostBrightness,
    McpLogMessageHandler? onMcpLogMessage,
    SettingsStore? settingsStore,
    // Platform integration (FR-PLATFORM). All optional — when the shell
    // injects nothing the NoOp ports and pauseResume policy apply, which is
    // correct for desktop/web hosts without native background support.
    BackgroundPolicy backgroundPolicy = BackgroundPolicy.pauseResume,
    BackgroundExecutionPort? backgroundPort,
    PlatformPermissionPort? permissionPort,
    AppNotificationPort? notificationPort,
    ConsentPrompt? consentPrompt,
    ConsentStore? consentStore,
    MemoryReclaimer? memoryReclaimer,
    // Debug MCP (FR-DEBUG) — a desktop-only, settings-gated MCP endpoint
    // for test automation (screenshot / tree / tap / type). The desktop
    // gate is enforced here in core, so hosts may pass the raw user pref.
    bool enableDebugMcp = false,
    int debugMcpPort = 7930,
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
    // A reconnect hands out a NEW client, and everything that lives on the
    // client is gone with the old one: the notification handler and the
    // server-side `resources/subscribe`. An app left open across a
    // background round trip kept working for tool calls (those resolve the
    // live client per call) and stopped streaming, with Subscribe doing
    // nothing because the runtime binding was still registered. Re-attach
    // both to the new client.
    _conn.onClientAttached = _reattachOpenApps;
    _tenant = TenantResolver(source: tenantSource, logger: _logger);
    _bundleLoader = BundleLoaderAdapter(
      fetcher: bundleFetcher,
      logger: _logger,
      metrics: _metrics,
      installRoot: bundleInstallRoot,
      installStore: bundleInstallStore,
    );
    _bundleResolver = const BundleResolver();
    _bundleAdapter = BundleApplicationAdapter(logger: _logger);
    // A host that supplied storage has no directory to install into —
    // `bundleInstallRoot` is then whatever placeholder it passed, and
    // must not be used as one.
    _bundleInstaller = bundleInstallStore != null
        ? BundleInstallerAdapter.onStore(
            store: bundleInstallStore,
            logger: _logger,
          )
        : BundleInstallerAdapter(
            installRoot: bundleInstallRoot,
            logger: _logger,
          );
    _metadataProvider = AppMetadataProvider(
      sink: appMetadataSink,
      logger: _logger,
    );
    _hostBrightness = hostBrightness;
    _onMcpLogMessage = onMcpLogMessage;

    // Bridge the UI DSL runtime's diagnostics to whoever asked for them.
    // Installed once, at initialize: the runtime logger is static, and a
    // handler wired later would miss everything a document said while it was
    // being loaded — which is when most of what it has to say happens.
    if (onRuntimeLog != null) {
      MCPLogger.onRecord = onRuntimeLog;
      _runtimeLogInstalled = true;
    }
    _settingsStore = settingsStore ?? InMemorySettingsStore();

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

    // Platform integration foundation (FR-PLATFORM). Ports default to NoOp;
    // the real native adapters arrive once `appplayer_core` is promoted to a
    // Flutter plugin. Continuity pauses/reconnects the ConnectionManager and
    // the health monitor across background transitions; the scheduler runs
    // periodic jobs; the lifecycle coordinator applies `backgroundPolicy`.
    _background = backgroundPort ?? defaultBackgroundPort(logger: _logger);
    _permissions = permissionPort ?? defaultPermissionPort(logger: _logger);
    _notifications =
        notificationPort ?? defaultNotificationPort(logger: _logger);
    await _background.initialize(backgroundPolicy);
    _continuity = ConnectionContinuity(
      connections: _conn,
      healthMonitor: _health,
      logger: _logger,
    );
    _scheduler = JobScheduler(background: _background, logger: _logger);
    _consent = consentPrompt == null
        ? null
        : CapabilityConsentManager(
            store: consentStore ?? InMemoryConsentStore(),
            prompt: consentPrompt,
            permissions: _permissions,
            logger: _logger,
          );
    _lifecycle = LifecycleCoordinator(
      continuity: _continuity,
      background: _background,
      policy: backgroundPolicy,
      scheduler: _scheduler,
      memory: memoryReclaimer,
      logger: _logger,
      // Desktop does not suspend the process — window hide/minimize must not
      // pause or disconnect connections. Only mobile drives continuity pause.
      //
      // `kIsWeb` comes first because `Platform` is `dart:io` and throws on the
      // web; this line ran before the first frame, so the whole host rendered
      // blank. False is also the truthful value there rather than a dodge — a
      // tab has no process to suspend, and no native background port is
      // injected for continuity to pause against.
      platformSuspends: !kIsWeb && (Platform.isAndroid || Platform.isIOS),
    );

    // Boot brain_kernel so the bundle's 8 knowledge categories and the
    // standard tool surface are ready: `KnowledgeSystem`, the five
    // runtimes, and the activation `Registry`. The bridge boots cleanly
    // even when KV / LLM are not injected by using in-memory and stub
    // ports; real resources land in a follow-up round. The boot is
    // wrapped in try/catch so a brain_kernel failure does not bring
    // down chrome (a safety net while the knowledge-operations gaps
    // 1–3 fixes are still rolling out).
    try {
      _kernel = await KernelApp.boot(
        workspaceId: workspaceId,
        kvStorage: InMemoryKvStoragePort(),
        // Co-locate the BM25 retrieval store with the bundle install
        // root so it is cleaned up alongside the bundles themselves.
        bundleRegistryStorageDir: bundleInstallRoot,
        // Outbound MCP client surface the `mcp.*` tools drive. Holds no
        // connection until an app calls `mcp.connect`, so booting with it
        // is free for apps that never reach out. Separate from the UI's
        // `ConnectionManager` (user-configured server list) by design —
        // these are app-driven programmatic connections.
        clientHost: McpClientKernelHost(),
      );
      // Register the standard tool surface (Layer 2) with the in-process
      // dispatcher. Adapt the kernel
      // handler type (`Future<Object?>`) into the dispatcher's
      // `Future<dynamic>` typedef.
      final tools = standardTools(_kernel!);
      // `mcp.*` (mcp_client as host tools, app-driven) shares the exact
      // same shape (`InProcessToolHandler`), so it registers through the
      // same adapt loop. Only present because the kernel booted with a
      // `clientHost`.
      final clientHost = _kernel!.clientHost;
      if (clientHost != null) {
        tools.addAll(clientTools(clientHost));
      }
      final adapted = <String, Future<dynamic> Function(Map<String, dynamic>)>{};
      for (final entry in tools.entries) {
        adapted[entry.key] = (Map<String, dynamic> args) async {
          return entry.value(args);
        };
      }
      _toolDispatcher.registerInProcessTools(adapted);
      // bundle_host_bridge — owns session lifecycle + Zone-scoped
      // scopeId + kb:// URI resolution. Created
      // after the kernel boot so `systemResolver` always returns a
      // booted KnowledgeSystem.
      _bridge = BundleSessionBridge(
        systemResolver: () => _kernel?.system,
      );
    } catch (e) {
      _logger.warn('KernelApp boot failed', null, e);
    }

    // Debug MCP surface (FR-DEBUG). All native platforms (desktop AND
    // mobile) — capture + input injection are platform-agnostic; a mobile
    // app's localhost endpoint is reachable via adb forward / iOS-sim
    // loopback. Only web is excluded (no dart:io HttpServer). The `!kIsWeb`
    // guard short-circuits before any `Platform.*` access. Booting the
    // transport is wrapped so a bind failure (port in use) never brings down
    // the app.
    final supported = !kIsWeb;
    if (enableDebugMcp && supported) {
      try {
        final surface = DebugSurface();
        final host = DebugMcpHost(surface);
        await host.start(port: debugMcpPort);
        _debugSurface = surface;
        _debugMcpHost = host;
        _logger.info('Debug MCP host started on 127.0.0.1:$debugMcpPort/mcp');
      } catch (e) {
        _debugSurface = null;
        _debugMcpHost = null;
        _logger.warn('Debug MCP host start failed', null, e);
      }
    }

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

  /// FR-META-006 — connect and read `ui://app/info` ONLY, without loading the
  /// UI or initialising a runtime. This is the "install / register a server"
  /// step: it populates the launcher tile (name / icon / publisher) so the
  /// user sees the app before ever opening it — the UI is rendered later, on
  /// tap, via [openAppFromServer]. Mirrors how a local server is added
  /// (metadata first, render on open), instead of rendering the app the
  /// moment it is installed.
  ///
  /// Returns the published [AppMetadata] (null when the server exposes none).
  /// The connection is opened only to read the metadata and is **closed
  /// again** before returning — install is metadata-only, so it must not hold
  /// a live socket. The real connection is re-established later, on tap, by
  /// [openAppFromServer] (mirrors adding a local server: connect, read, close;
  /// reconnect on open).
  Future<AppMetadata?> fetchServerMetadata(String serverId) async {
    _assertReady();
    return _withTenantGuard(
      serverId: serverId,
      operation: () => _fetchServerMetadataImpl(serverId),
    );
  }

  Future<AppMetadata?> _fetchServerMetadataImpl(String serverId) async {
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

    try {
      // List first (reveals whether ui://app/info exists), then read it with a
      // retry when it is listed. No runtime, no UI — this is metadata-only.
      final resources = await client.listResources();
      final infoListed = resources
          .any((r) => r.uri == AppMetadataProvider.wellKnownUri);
      final metadata = await _metadataProvider.fetchFromServer(
        client,
        serverId,
        retries: infoListed ? 3 : 0,
      );
      await _metadataProvider.publish(metadata);
      if (metadata != null) {
        _metadataCache[AppHandle.server(serverId)] = metadata;
      }
      _logger.debug('server.metadata.prefetch', {
        'serverId': serverId,
        'metadata': metadata != null,
        'infoListed': infoListed,
      });
      return metadata;
    } finally {
      // Install is metadata-only: close the connection once the metadata is
      // read. The socket is re-established on the first real open (tap).
      await _conn.disconnect(serverId);
    }
  }

  /// FR-CORE-002 — Online path (MCP server serves `ui://` application).
  ///
  /// [trustLevel] gates which `client.*` actions the runtime will
  /// execute. The launcher chooses a level per-app (default `basic`).
  /// See `flutter_mcp_ui_runtime/TrustLevel` for the hierarchy.
  /// [entry] / [identity] carry how this app was reached and who is looking
  /// at it (MCP UI DSL 8.9, platform spec 19). Both are absent for an app
  /// opened from the launcher; an [entry] naming a route opens the app on
  /// that page instead of its own initial route.
  Future<AppSession> openAppFromServer(
    String serverId, {
    TrustLevel trustLevel = TrustLevel.basic,
    EntryContext? entry,
    IdentityContext? identity,
    String? launchRoute,
  }) async {
    _assertReady();
    return _withTenantGuard(
      serverId: serverId,
      operation: () => _openFromServerImpl(
          serverId, trustLevel, entry, identity, launchRoute),
    );
  }

  Future<AppSession> _openFromServerImpl(String serverId, TrustLevel trustLevel,
      [EntryContext? entry,
      IdentityContext? identity,
      String? launchRoute]) async {
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
    // MCP Serving 1.0 — populated on the first open when the server exposes a
    // bundle document (see below); carried into the session for teardown.
    McpBundle? servedBundle;
    _JsToolWireState? jsState;
    String? servedBundleId;
    if (!runtime.isInitialized) {
      // List the server's resources FIRST — it warms the connection and the
      // resource cache, and reveals whether `ui://app/info` actually exists.
      // Reading metadata before this (against a cold, just-handshook stream)
      // was the intermittent "app opens but metadata missing" race: a single
      // best-effort read raced server/transport readiness and silently
      // yielded null, so the tile kept its fallback name until the user
      // re-entered enough times to hit a lucky timing. The list is reused for
      // both UI load and MCP Serving bundle-document detection (one round-trip).
      final resources = await client.listResources();

      // Metadata read on the now-warm connection. When the server actually
      // exposes `ui://app/info`, a null/error is transient (cold start,
      // stream not ready) — retry with a short backoff instead of giving up
      // after one shot. Unlisted → single best-effort attempt (a server may
      // serve it without listing, but don't hammer one that simply lacks it).
      final infoListed = resources
          .any((r) => r.uri == AppMetadataProvider.wellKnownUri);
      metadata = await _metadataProvider.fetchFromServer(
        client,
        serverId,
        retries: infoListed ? 3 : 0,
      );
      await _metadataProvider.publish(metadata);
      if (metadata != null) {
        _metadataCache[handle] = metadata;
      }

      // MCP Serving 1.0 §"Rules" 2 (Equivalence) — a served bundle must behave
      // identically to the same bundle run locally. The local path resolves
      // `bundle://` against the bundle's own assets before the runtime ever
      // sees the definition (mcp_ui_dsl §6.12.7, placement 1); the served path
      // has to do the same, or the identical document renders in one and
      // shows nothing in the other. So the document is read *before* the UI
      // rather than after it — the resource list above already tells us
      // whether it is there, at no extra round-trip.
      if (resources.any((r) => r.uri == _bundleDocumentUri)) {
        try {
          final res = await client.readResource(_bundleDocumentUri);
          final text = res.contents.isEmpty ? null : res.contents.first.text;
          if (text != null && text.isNotEmpty) {
            final decoded = jsonDecode(text);
            if (decoded is Map<String, dynamic>) {
              servedBundle = McpBundleLoader.fromJson(decoded);
            }
          }
        } catch (e) {
          _logger.warn(
            'served bundle document reconstruct failed',
            {'serverId': serverId},
            e,
          );
        }
      }
      // Resolver over the served bundle's own assets. Absent a bundle
      // document there is nothing to resolve against, and `bundle://` in that
      // document is an unresolvable asset (§6.12.4) — not an error.
      final servedUriResolver = servedBundle == null
          ? null
          : BundleUriResolver(assets: servedBundle.assets, logger: _logger);

      final loaded = await _appLoader.load(client, resources: resources);
      // Run every server app through AppPlayer's standard app-execution
      // structure: promote a bare `page` to a single-route application so the
      // runtime mounts routing (route -> MCPPageWidget frames the page and
      // lifts its `title` into an AppBar) and the dashboard/navigation slots
      // come live. A server that already serves an application passes through
      // unchanged. pickAppUri returns the same uri load() just read.
      final appUri = _appLoader.pickAppUri(resources);
      final rawDefinition = appUri == null
          ? loaded
          : _appLoader.wrapAsApplication(loaded, appUri: appUri);
      final definition = servedUriResolver == null
          ? rawDefinition
          : servedUriResolver.rewriteDefinition(rawDefinition)
              as Map<String, dynamic>;
      final wrapped = !identical(definition, loaded);
      _logger.debug('server.open.first', {
        'serverId': serverId,
        'metadata': metadata != null,
        'infoListed': infoListed,
        'resources': resources.length,
        'defKeys': definition.keys.take(8).join(','),
        'wrapped': wrapped,
        'hasTheme': definition['theme'] != null ||
            (definition['runtime'] as Map?)?['services']?['theme'] != null,
      });
      // When we promoted the page, serve its already-parsed content back to
      // the route from memory instead of re-reading it over the (possibly
      // dead) link — so the app's first frame, and its exit affordance,
      // always render (see cachingPageLoaderFor).
      await runtime.initialize(
        definition,
        pageLoader: wrapped && appUri != null
            ? _appLoader.cachingPageLoaderFor(
                client,
                {appUri: loaded},
                transform: servedUriResolver == null
                    ? null
                    : (page) => servedUriResolver.rewriteDefinition(page)
                        as Map<String, dynamic>,
              )
            : _appLoader.pageLoaderFor(
                client,
                transform: servedUriResolver == null
                    ? null
                    : (page) => servedUriResolver.rewriteDefinition(page)
                        as Map<String, dynamic>,
              ),
        entry: entry,
        identity: identity,
        launchRoute: launchRoute,
      );
      _reportLaunchRoute(runtime, entry?.route ?? launchRoute);
      runtime.setTrustLevel(trustLevel);
      _applyStreamSources(runtime);
      _applyDefinitionResolver(runtime);
      _notifRouter.register(
        client: client,
        runtime: runtime,
        serverId: serverId,
        onMcpLogMessage: _onMcpLogMessage,
      );

      // The document was read before the UI (above) so its assets could
      // resolve. Its declarative sections (knowledge / settings / behavior /
      // tool declarations) come live here, identical to a local bundle. Tool
      // execution stays remote (`tools/call`).
      if (servedBundle != null) {
        servedBundleId = servedBundle.manifest.id;
        jsState = await _activateBundleSections(servedBundle, servedBundleId);
      }
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
      // Set when the server exposed a bundle document (MCP Serving 1.0).
      bundle: servedBundle,
      jsRuntime: jsState?.runtime,
      jsToolNames: jsState?.toolNames ?? const <String>[],
      onClose: servedBundleId == null
          ? null
          : () async {
              final id = servedBundleId!;
              final session = _sessions.remove(id);
              if (session != null) await _bridge?.closeSession(session);
              await _kernel?.deactivate(id);
            },
    );
  }

  /// FR-META-007 — load a bundle's manifest and publish its metadata
  /// (name / icon / publisher) WITHOUT adapting the definition or building a
  /// runtime. The bundle twin of [fetchServerMetadata]: "installing a
  /// bundle" only writes it to disk (`installBundleFromFile`), so call this
  /// right after to populate the launcher card — otherwise the tile shows
  /// the raw bundle id until the user first opens it. The UI is rendered
  /// later, on open ([openAppFromBundle]).
  Future<AppMetadata> fetchBundleMetadata(BundleRef bundleRef) async {
    _assertReady();
    final bundle = await _bundleLoader.load(bundleRef);
    final uriResolver =
        BundleUriResolver(assets: bundle.assets, logger: _logger);
    final metadata = _metadataProvider.fromBundle(bundle, uriResolver);
    await _metadataProvider.publish(metadata);
    _metadataCache[AppHandle.bundle(bundle.manifest.id)] = metadata;
    _logger.debug('bundle.metadata.prefetch', {'bundleId': bundle.manifest.id});
    return metadata;
  }

  /// Log an entry whose route this app no longer declares.
  ///
  /// The runtime already fell back to the app's own initial route; what must
  /// not happen is that falling back looks like success. A stale binding that
  /// silently renders the home page is indistinguishable from a working one,
  /// so the miss is surfaced here for the host to disclose (spec 19 §4.3).
  void _reportLaunchRoute(MCPUIRuntime runtime, String? requested) {
    if (requested == null) return;
    if (runtime.engine.routeManager?.launchRouteMissing ?? false) {
      _logger.warn('launch.route.missing', {
        'requested': requested,
        'rendered': runtime.engine.routeManager?.initialRoute,
      });
    }
  }

  /// FR-CORE-003 — Local Bundle path (`McpBundle` file / inline JSON).
  Future<AppSession> openAppFromBundle(
    BundleRef bundleRef, {
    TrustLevel trustLevel = TrustLevel.basic,
    EntryContext? entry,
    IdentityContext? identity,
    String? launchRoute,
  }) async {
    _assertReady();
    final bundle = await _bundleLoader.load(bundleRef);
    final bundleId = bundle.manifest.id;

    return _withTenantGuard(
      bundleId: bundleId,
      operation: () =>
          _openFromBundleImpl(bundle, trustLevel, entry, identity, launchRoute),
    );
  }

  Future<AppSession> _openFromBundleImpl(McpBundle bundle, TrustLevel trustLevel,
      [EntryContext? launchEntry,
      IdentityContext? identity,
      String? launchRoute]) async {
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
        entry: launchEntry,
        identity: identity,
        launchRoute: launchRoute,
      );
      _reportLaunchRoute(runtime, launchEntry?.route ?? launchRoute);
    } else if (launchEntry != null) {
      // A runtime already built for this handle keeps its route, but the
      // entry that reached it now is still the current one — a second scan of
      // the same medium must not render the first scan's context.
      runtime.entrySession.adoptEntry(launchEntry);
      if (identity != null) runtime.entrySession.adoptIdentity(identity);
    }
    runtime.setTrustLevel(trustLevel);
    _applyStreamSources(runtime);
    _applyDefinitionResolver(runtime);

    // Activate declarative sections, expose the bundle document, and wire
    // in-process JS tools. Shared with the served-bundle path
    // (`_openFromServerImpl`) — see [_activateBundleSections].
    final jsState = await _activateBundleSections(bundle, bundleId);

    return AppSessionImpl(
      handle: handle,
      runtime: runtime,
      conn: _conn,
      runtimeManager: _runtime,
      toolDispatcher: _toolDispatcher,
      resourceSubscriber: _resourceSub,
      logger: _logger,
      metadata: metadata,
      bundle: bundle,
      hostBrightness: _hostBrightness,
      jsRuntime: jsState?.runtime,
      jsToolNames: jsState?.toolNames ?? const <String>[],
      onClose: () async {
        final session = _sessions.remove(bundleId);
        if (session != null) await _bridge?.closeSession(session);
        await _kernel?.deactivate(bundleId);
      },
    );
  }

  /// MCP Serving 1.0 — activate a bundle's
  /// declarative sections (knowledge / settings / behavior / tool
  /// declarations) on the kernel, open a bridge session, expose the bundle
  /// document at `bundle://manifest.json`, and wire in-process JS tools.
  ///
  /// Shared by the local-bundle path ([_openFromBundleImpl]) and the
  /// served-bundle path ([_openFromServerImpl], when a server exposes the
  /// document). Tool execution is unaffected — JS tools run in-process on the
  /// host, and non-JS tool calls dispatch wherever the dispatcher routes
  /// them. Returns the JS wire state so the caller tears it down on close.
  Future<_JsToolWireState?> _activateBundleSections(
    McpBundle bundle,
    String bundleId,
  ) async {
    // brain_kernel BundleActivation — registers every manifest category
    // (skill / profile / philosophy / fact / flow / agent plus tools and
    // knowledge.sources). Silently skipped when the bridge is not booted.
    try {
      await _kernel?.activate(bundle, bundleIdOverride: bundleId);
      // Open a bridge session so JS / agent / workflow dispatch within this
      // bundle inherits the right `scopeId` via Zone, and so any UI mount /
      // stream subscription tied to the session is torn down on close. The
      // session map is keyed by bundleId — re-activation reuses the slot.
      final activation = _kernel?.activationRegistry.get(bundleId);
      if (activation != null &&
          _bridge != null &&
          !_sessions.containsKey(bundleId)) {
        _sessions[bundleId] = _bridge!.openSession(activation);
      }
    } catch (e) {
      _logger.warn('KernelApp.activate failed', {'bundleId': bundleId}, e);
    }

    // Expose the activated bundle as the well-known `bundle://manifest.json`
    // document resource so a connected client can reconstruct and run it
    // identically (equivalence rule). Purely additive: kb:// / tools serving
    // is unchanged, and when a server host wires `resourceServerAdapter` the
    // registration also lands on resources/list for external discovery.
    _bridge?.registerResource(
      _bundleDocumentUri,
      (_) async => bundle.toJson(),
      name: bundle.manifest.name,
      description: 'Bundle document — manifest metadata and sections',
      mimeType: 'application/json',
    );

    // JS tools (`tools[].kind=js`) run in-process on the host — for a served
    // bundle too (script tools are host-side per the serving contract).
    return _wireJsTools(bundle, bundleId);
  }

  Future<_JsToolWireState?> _wireJsTools(
    McpBundle bundle,
    String bundleId,
  ) async {
    final tools = bundle.tools?.tools ?? const [];
    final jsEntries = tools.where((t) => t.kind == ToolKind.js).toList();
    if (jsEntries.isEmpty) return null;
    // Read the entry scripts through the bundle's own file surface. A
    // path would restrict JS tools to hosts that can resolve one, and
    // the bundle already knows where its files are.
    final bundleFiles = bundle.fileStore;
    if (bundleFiles == null) {
      _logger.warn(
        'JS tools declared but bundle carries no files — skip',
        {'bundleId': bundleId},
      );
      return null;
    }

    final runtime = JsToolRuntime();
    final session = _sessions[bundleId];
    final atoms = <AtomCategory>[
      McpAtom(_toolDispatcher, bridge: _bridge, session: session),
      if (_kernel != null)
        AgentAtom(_kernel!, bridge: _bridge, session: session),
      BundleAtom(bundle: bundle),
    ];
    // When the manifest declares `requires.builtinAtoms`, expose only
    // that set. Otherwise expose every atom the core provides. Host
    // security policies (Standard / Pro) are layered on top later
    // (atoms registry hardening lands separately).
    final required = bundle.requires?.builtinAtoms ?? const <String>[];
    final allowed = required.isEmpty
        ? atoms.map((a) => a.key)
        : required;
    try {
      await runtime.attachHostBridge(atoms: atoms, allowedAtoms: allowed);
    } catch (e) {
      _logger.warn('attachHostBridge failed', {'bundleId': bundleId}, e);
      await runtime.dispose();
      return null;
    }

    final registered = <String>[];
    for (final t in jsEntries) {
      final entry = t.target['entry'];
      final fn = t.target['fn'];
      if (entry is! String || fn is! String) continue;
      String code;
      try {
        final bytes = await bundleFiles.read(entry);
        if (bytes == null) {
          _logger.warn(
            'JS tool entry not found in bundle',
            {'tool': t.name, 'entry': entry},
          );
          continue;
        }
        code = utf8.decode(bytes);
      } catch (e) {
        _logger.warn(
          'JS tool entry read failed',
          {'tool': t.name, 'entry': entry},
          e,
        );
        continue;
      }
      try {
        final r = await runtime.evaluate(code, sourceUrl: entry);
        if (r.isError) {
          _logger.warn(
            'JS tool entry evaluate error',
            {'tool': t.name},
            r.stringResult,
          );
          continue;
        }
      } catch (e) {
        _logger.warn('JS tool entry evaluate threw', {'tool': t.name}, e);
        continue;
      }
      final toolName = t.name;
      _toolDispatcher.registerInProcessTool(toolName, (params) async {
        final call = '$fn(${jsonEncode(params)})';
        final r = await runtime.evaluateAsync(
          'Promise.resolve($call)',
          sourceUrl: toolName,
        );
        if (r.isError) {
          throw Exception('JS tool $toolName failed: ${r.stringResult}');
        }
        try {
          return jsonDecode(r.stringResult);
        } catch (_) {
          return r.stringResult;
        }
      });
      registered.add(toolName);
    }

    return _JsToolWireState(runtime: runtime, toolNames: registered);
  }

  /// Called by host shells (Standard chrome, Pro launcher, ...) when the
  /// visible bundle (the active tab/window) changes. Keeps the brain_kernel
  /// dispatch wrapper context — the auto-composed `<bundleId>.*` prefix —
  /// in sync. Passing `null` means the host itself is in front (home or
  /// launcher view), which is interpreted as the master context.
  /// Idempotent — repeating the same handle is a no-op.
  void setActiveSession(AppHandle? handle) {
    _assertReady();
    _kernel?.setActiveBundle(
      handle?.source == AppSource.bundle ? handle?.key : null,
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
    } else if (handle.source == AppSource.bundle) {
      // Also tear down the brain_kernel BundleActivation. The
      // `AppSession.close` onClose hook performs the same operation;
      // duplicating it here guarantees the catalog is cleared even on
      // the path where the host calls `closeApp(handle)` directly.
      try {
        final session = _sessions.remove(handle.key);
        if (session != null) await _bridge?.closeSession(session);
        await _kernel?.deactivate(handle.key);
      } catch (e) {
        _logger.warn(
          'KernelApp.deactivate failed',
          {'bundleId': handle.key},
          e,
        );
      }
    }
  }

  // Bundle install lifecycle (FR-INSTALL-001~005).
  //
  // Every install/uninstall invalidates the bundle's cached runtime +
  // metadata: `_openFromBundleImpl` reuses an already-initialized runtime for
  // the same bundle id (`if (!runtime.isInitialized)`), so without this a
  // reinstall/update kept rendering the OLD definition for the rest of the
  // session (fresh only after an app restart).
  /// Install a bundle from `.mcpb` bytes (FR-INSTALL-001).
  ///
  /// For hosts that fetched the archive themselves and have no path to
  /// hand — a browser shell installing a purchased bundle.
  Future<InstalledAppBundle> installBundleFromBytes(Uint8List bytes) async {
    _assertReady();
    final installed = await _bundleInstaller.installBytes(bytes);
    await _invalidateBundleCaches(installed.id);
    return installed;
  }

  Future<InstalledAppBundle> installBundleFromFile(String filePath) async {
    _assertReady();
    final installed = await _bundleInstaller.installFile(filePath);
    await _invalidateBundleCaches(installed.id);
    return installed;
  }

  Future<InstalledAppBundle> installBundleFromDirectory(String mbdPath) async {
    _assertReady();
    final installed = await _bundleInstaller.installDirectory(mbdPath);
    await _invalidateBundleCaches(installed.id);
    return installed;
  }

  Future<InstalledAppBundle> installBundleFromUrl(Uri url) async {
    _assertReady();
    final installed = await _bundleInstaller.installUrl(url);
    await _invalidateBundleCaches(installed.id);
    return installed;
  }

  Future<void> uninstallBundle(String bundleId) async {
    _assertReady();
    await _bundleInstaller.uninstall(bundleId);
    await _invalidateBundleCaches(bundleId);
  }

  /// Drop the session-scoped runtime + metadata cached for [bundleId] so the
  /// next open re-initializes from the bundle now on disk.
  Future<void> _invalidateBundleCaches(String bundleId) async {
    final handle = AppHandle.bundle(bundleId);
    if (_runtime.hasRuntime(handle)) {
      await _runtime.removeRuntime(handle);
    }
    _metadataCache.remove(handle);
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

  // --- Platform integration (FR-PLATFORM) -------------------------------

  /// Forward an OS lifecycle transition (FR-LIFE-001). The shell's
  /// `WidgetsBindingObserver` maps `AppLifecycleState` to [AppLifecyclePhase]
  /// and calls this; the coordinator applies the configured
  /// [BackgroundPolicy] — pausing/reconnecting connections and the health
  /// monitor, and pausing/resuming scheduled jobs.
  Future<void> onLifecyclePhase(AppLifecyclePhase phase) =>
      _lifecycle.onPhase(phase);

  /// Periodic / scheduled background jobs (FR-SCHED). Hosts register jobs
  /// (health sweeps, data pulls) that run on a foreground timer and delegate
  /// to the platform background task while suspended.
  JobScheduler get scheduler => _scheduler;

  /// Per-app capability consent (FR-CAP). Null unless the shell injected a
  /// [ConsentPrompt] in [initialize] — pure-Dart hosts without a consent UI
  /// have no enforcement point.
  CapabilityConsentManager? get consent => _consent;

  /// OS permission port (FR-PERM) for shell-driven, lazy permission requests.
  PlatformPermissionPort get permissions => _permissions;

  /// Notification port (FR-NOTIF) apps post through and the shell renders.
  AppNotificationPort get notifications => _notifications;

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

  /// Persists user values declared by the bundle's
  /// `settings.sections[].fields[]` schema. Hosts inject their own
  /// implementation (SharedPreferences, SecureStorage, files, ...) via
  /// `initialize(settingsStore: ...)`. When not provided the core falls
  /// back to the in-memory default, which clears on process restart.
  SettingsStore get settings {
    _assertReady();
    return _settingsStore;
  }

  /// Wire the durable-reconnect token re-grant (see [ServerReGrant]). Call once
  /// after [initialize], when the marketplace session exists (capabilities are
  /// built after composition). A stale marketplace connectionToken is then
  /// silently refreshed on connect / reconnect / health-monitor auto-reconnect
  /// instead of requiring a manual reinstall. Pass null to clear it. Hosts
  /// without a marketplace (Standard / hand-typed / discovered) never call this,
  /// so their connect behaviour is unchanged.
  set serverReGrant(ServerReGrant? hook) {
    _assertReady();
    _conn.tokenReGrant = hook;
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

  /// Re-binds an open app's per-connection state onto a freshly attached
  /// client. Runs on first connect too, where it is a no-op: nothing has
  /// subscribed yet and the open path registers its own handler.
  void _reattachOpenApps(String serverId, Client client) {
    // Every runtime fed by THIS server, not just the full-screen app: a
    // composed dashboard tile watches the same device through its own summary
    // runtime and would otherwise be the one surface still frozen after a
    // resume.
    for (final handle in <AppHandle>[
      AppHandle.server(serverId),
      DashboardOrchestrator.deviceSummaryRuntimeHandle(serverId),
    ]) {
      final runtime = _runtime.getRuntime(handle);
      if (runtime == null) continue;
      _notifRouter.register(
        client: client,
        runtime: runtime,
        serverId: serverId,
        onMcpLogMessage: _onMcpLogMessage,
      );
      unawaited(_resourceSub
          .reattach(client: client, runtime: runtime, ownerKey: handle.key)
          .catchError((Object e, StackTrace st) {
        _logger.logError('reattach after reconnect failed', e, st,
            {'serverId': serverId, 'handle': handle.toString()});
      }));
    }
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
    if (_runtimeLogInstalled) {
      // Only this service's own bridge is removed: the hook is static, and
      // tearing down a handler another instance installed would silence it.
      MCPLogger.onRecord = null;
      _runtimeLogInstalled = false;
    }
    try {
      await _debugMcpHost?.stop();
    } catch (e) {
      _logger.warn('Debug MCP host stop failed', null, e);
    }
    _debugMcpHost = null;
    _debugSurface = null;
    _health.stopMonitoring();
    await _lifecycle.dispose();
    _scheduler.dispose();
    await _dashboard.close();
    _activeDashboardSession = null;
    await _runtime.removeAllRuntimes();
    await _conn.disconnectAll();
    _metadataCache.clear();
    // Close every open bridge session before tearing down the
    // kernel so attached UI mounts / subscriptions get a chance to
    // clean up against a still-booted KnowledgeSystem.
    for (final session in List<DispatchSession>.from(_sessions.values)) {
      try {
        await _bridge?.closeSession(session);
      } catch (_) {/* best-effort */}
    }
    _sessions.clear();
    _bridge = null;
    try {
      await _kernel?.shutdown();
    } catch (e) {
      _logger.warn('KernelApp.shutdown failed', null, e);
    }
    _initialized = false;
    _logger.info('AppPlayerCoreService disposed');
  }
}
