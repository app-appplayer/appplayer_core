import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:ui' show Brightness;

import 'package:flutter/foundation.dart'
    show Listenable, ValueListenable, visibleForTesting;
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
        standardTools;
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

/// Internal wire state for per-session JS tools — held by `AppSessionImpl`
/// so `close()` can tear down the isolate + unregister dispatcher entries.
class _JsToolWireState {
  _JsToolWireState({required this.runtime, required this.toolNames});
  final JsToolRuntime runtime;
  final List<String> toolNames;
}

/// MCP Serving 1.0 — well-known resource URI carrying the whole bundle
/// document (manifest metadata + sections) for `resources/read`. Reuses the
/// existing `bundle://` scheme (mcp_ui_dsl §11.5); no new scheme.
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
  KernelApp? _kernel;
  BundleSessionBridge? _bridge;
  final Map<String, DispatchSession> _sessions =
      <String, DispatchSession>{};

  bool _initialized = false;

  /// Test-only — whether brain_kernel boot succeeded. Production code
  /// goes through the public surface (open* / setActiveSession /
  /// dispose); only regression suites inspect this directly.
  @visibleForTesting
  bool get isKernelBooted => _kernel != null;

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

  /// FR-CORE-001
  ///
  /// [workspaceId] — the workspace identifier passed to brain_kernel's
  /// `FlowBrainWiring`. Hosts pick their own value (for example
  /// `appplayer.standard` / `appplayer.pro` / etc.). Defaults to
  /// `appplayer` when unspecified.
  Future<void> initialize({
    required ServerStorage storage,
    required String bundleInstallRoot,
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

    // Boot brain_kernel so the bundle's 8 knowledge categories and the
    // standard tool surface are ready: `KnowledgeSystem`, the five
    // runtimes, and the activation `Registry`. The bridge boots cleanly
    // even when KV / LLM are not injected by using in-memory and stub
    // ports; real resources land in a follow-up round. The boot is
    // wrapped in try/catch so a brain_kernel failure does not bring
    // down chrome (a safety net while the knowledge-operations.md gaps
    // 1–3 fixes are still rolling out).
    try {
      _kernel = await KernelApp.boot(
        workspaceId: workspaceId,
        kvStorage: InMemoryKvStoragePort(),
        // Co-locate the BM25 retrieval store with the bundle install
        // root so it is cleaned up alongside the bundles themselves.
        bundleRegistryStorageDir: bundleInstallRoot,
      );
      // Register the standard tool surface (knowledge-operations.md §5
      // Layer 2) with the in-process dispatcher. Adapt the kernel
      // handler type (`Future<Object?>`) into the dispatcher's
      // `Future<dynamic>` typedef.
      final tools = standardTools(_kernel!);
      final adapted = <String, Future<dynamic> Function(Map<String, dynamic>)>{};
      for (final entry in tools.entries) {
        adapted[entry.key] = (Map<String, dynamic> args) async {
          return entry.value(args);
        };
      }
      _toolDispatcher.registerInProcessTools(adapted);
      // bundle_host_bridge — owns session lifecycle + Zone-scoped
      // scopeId + kb:// URI resolution (PORTING_GUIDE §5b). Created
      // after the kernel boot so `systemResolver` always returns a
      // booted KnowledgeSystem.
      _bridge = BundleSessionBridge(
        systemResolver: () => _kernel?.system,
      );
    } catch (e) {
      _logger.warn('KernelApp boot failed', null, e);
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
    // MCP Serving 1.0 — populated on the first open when the server exposes a
    // bundle document (see below); carried into the session for teardown.
    McpBundle? servedBundle;
    _JsToolWireState? jsState;
    String? servedBundleId;
    if (!runtime.isInitialized) {
      metadata = await _metadataProvider.fetchFromServer(client, serverId);
      await _metadataProvider.publish(metadata);
      if (metadata != null) {
        _metadataCache[handle] = metadata;
      }

      // List the server's resources once and reuse for both UI load and
      // MCP Serving bundle-document detection (avoids a redundant round-trip).
      final resources = await client.listResources();
      final definition = await _appLoader.load(client, resources: resources);
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

      // MCP Serving 1.0 (specs/mcp_serving/spec/1.0) — if the server exposes
      // the bundle document, reconstruct the McpBundle and activate its
      // declarative sections (knowledge / settings / behavior / tool
      // declarations) so they come live, identical to a local bundle. Tool
      // execution stays remote (`tools/call`) and the UI still loads via
      // `ui://app` above. Absent the document, an existing ui://app-only
      // server is unaffected. Done once on the first open, never on reuse.
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

  /// MCP Serving 1.0 (specs/mcp_serving/spec/1.0) — activate a bundle's
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
    final dir = bundle.directory;
    if (dir == null) {
      _logger.warn(
        'JS tools declared but bundle has no directory — skip',
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
      final sep = Platform.pathSeparator;
      final entryPath = '$dir$sep${entry.replaceAll('/', sep)}';
      String code;
      try {
        code = await File(entryPath).readAsString();
      } catch (e) {
        _logger.warn(
          'JS tool entry read failed',
          {'tool': t.name, 'path': entryPath},
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

  /// Persists user values declared by the bundle's
  /// `settings.sections[].fields[]` schema. Hosts inject their own
  /// implementation (SharedPreferences, SecureStorage, files, ...) via
  /// `initialize(settingsStore: ...)`. When not provided the core falls
  /// back to the in-memory default, which clears on process restart.
  SettingsStore get settings {
    _assertReady();
    return _settingsStore;
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
