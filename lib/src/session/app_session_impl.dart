import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    show ThemeDefinition;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:mcp_bundle/mcp_bundle.dart' show McpBundle;
import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../js/js_tool_runtime.dart';

import '../connection/connection_manager.dart';
import '../logging/logger.dart';
import '../metadata/app_metadata.dart';
import '../runtime/resource_subscriber.dart';
import '../runtime/runtime_manager.dart';
import '../runtime/tool_dispatcher.dart';
import 'app_handle.dart';
import 'app_session.dart';

/// Concrete [AppSession] wiring tool/resource/notification callbacks around a
/// [MCPUIRuntime] so the host only consumes [buildWidget] (MOD-SESSION-001).
class AppSessionImpl implements AppSession {
  AppSessionImpl({
    required this.handle,
    required MCPUIRuntime runtime,
    required ConnectionManager conn,
    required RuntimeManager runtimeManager,
    required ToolDispatcher toolDispatcher,
    required ResourceSubscriber resourceSubscriber,
    required Logger logger,
    this.metadata,
    this.bundle,
    this.hostBrightness,
    JsToolRuntime? jsRuntime,
    List<String> jsToolNames = const <String>[],
    Future<void> Function()? onClose,
  })  : _runtime = runtime,
        _conn = conn,
        _runtimeManager = runtimeManager,
        _tools = toolDispatcher,
        _subs = resourceSubscriber,
        _logger = logger,
        _jsRuntime = jsRuntime,
        _jsToolNames = jsToolNames,
        _onClose = onClose;

  @override
  final AppHandle handle;

  @override
  AppSource get source => handle.source;

  @override
  final AppMetadata? metadata;

  @override
  final McpBundle? bundle;

  /// Host-provided brightness feed passed to `runtime.buildUI` so the
  /// DSL's `mode: 'system'` resolves against the launcher's theme choice.
  final ValueListenable<Brightness>? hostBrightness;

  @override
  bool get launchRouteMissing =>
      _runtime.engine.routeManager?.launchRouteMissing ?? false;

  final MCPUIRuntime _runtime;
  final ConnectionManager _conn;
  final RuntimeManager _runtimeManager;
  final ToolDispatcher _tools;
  final ResourceSubscriber _subs;
  final Logger _logger;
  final JsToolRuntime? _jsRuntime;
  final List<String> _jsToolNames;
  final Future<void> Function()? _onClose;

  bool _closed = false;

  Client? get _client => source == AppSource.server
      ? _conn.connections[handle.key]?.client
      : null;

  /// System baseline theme — REAL light AND dark token sets. An app that
  /// declares no theme must render on this, not on the runtime's bare
  /// `defaultLight()`: that default has no dark tokens, so a dark host pin
  /// over it produced the "weird dark" first entry (and entering a
  /// theme-declaring app like UI Showcase "fixed" it only by leaving its
  /// palette behind in the process-wide singleton).
  static final ThemeDefinition _systemBaselineTheme = ThemeDefinition.fromJson({
    ...ThemeDefinition.defaultLight().toJson(),
    'mode': 'system',
    'dark': ThemeDefinition.defaultDark().toJson(),
  });

  /// Which app currently owns the shared ThemeManager state — the runtime's
  /// ThemeManager is a process-wide singleton, so whatever the previous app
  /// applied leaks into the next one unless rebuilt on entry.
  static String? _themeStateOwner;

  /// Fingerprint of the singleton state as WE last applied it. The owner tag
  /// alone is not enough: runtime teardown paths reset the singleton behind
  /// the session's back (`MCPUIRuntime.destroy` → `ThemeManager.reset()`)
  /// without any host hook, so a same-app re-entry with a stale tag skipped
  /// rebaseline over the bare default (live: "same-app re-open weird,
  /// other-app detour normal"). The fingerprint embeds the theme-data map's
  /// identity hash — ANY external mutation invalidates the skip.
  static String? _themeAppliedFingerprint;

  /// Rebuild the theme state for THIS app on every entry/build.
  ///
  /// One-shot setup is not reliable (singleton residue + dispose clears the
  /// brightness pin), so entry is deterministic: the app's own declared
  /// theme — or the system baseline — is applied whenever ownership changed
  /// hands, and the CURRENT host brightness is re-pinned every time.
  void _rebaselineTheme() {
    final tm = _runtime.engine.themeManager;
    final owner = handle.toString();
    // Skip only when the singleton state is PROVABLY still ours: same owner
    // AND untouched fingerprint. A destroy/reset anywhere flips the
    // fingerprint, forcing a fresh apply.
    final intact = _themeStateOwner == owner &&
        _themeAppliedFingerprint == tm.fingerprint;
    if (!intact) {
      final own = _runtime.engine.applicationDefinition?.theme;
      if (own != null) {
        tm.setTheme(own);
      } else {
        tm.setThemeDefinition(_systemBaselineTheme);
      }
      _themeStateOwner = owner;
      _logger.debug('session.theme.rebaseline', {
        'handle': owner,
        'declared': own != null,
      });
    }
    final feed = hostBrightness;
    if (feed != null) tm.setHostBrightness(feed.value);
    _themeAppliedFingerprint = tm.fingerprint;
  }

  @override
  Widget buildWidget({
    required BuildContext context,
    VoidCallback? onExit,
  }) {
    _rebaselineTheme();
    return _runtime.buildUI(
      context: context,
      onToolCall: _onToolCall,
      onResourceSubscribe: _onResourceSubscribe,
      onResourceUnsubscribe: _onResourceUnsubscribe,
      onExit: onExit,
      hostBrightness: hostBrightness,
    );
  }

  @override
  Widget? buildDashboardWidget({
    required BuildContext context,
    VoidCallback? onExit,
    void Function(String? appId, String? route)? onOpenApp,
  }) {
    _rebaselineTheme();
    return _runtime.buildDashboard(
      context: context,
      onToolCall: _onToolCall,
      onResourceSubscribe: _onResourceSubscribe,
      onResourceUnsubscribe: _onResourceUnsubscribe,
      onExit: onExit,
      onOpenApp: onOpenApp,
      hostBrightness: hostBrightness,
    );
  }

  // Local bundle (no server client): still route host-registered in-process
  // capability tools (registerCapabilityTools, e.g. `provision.*`) directly
  // through the dispatcher — they need no external MCP client.
  Future<dynamic> _onToolCall(String tool, Map<String, dynamic> params) =>
      _tools.routerFor(
        _client,
        onNoClient: (t) => _logger.warn('session.tool.no_client', {
          'handle': handle.toString(),
          'tool': t,
        }),
      )(tool, params);

  Future<void> _onResourceSubscribe(String uri, String binding) async {
    final client = _client;
    if (client == null) {
      _logger.warn('session.subscribe.no_client', {
        'handle': handle.toString(),
        'uri': uri,
      });
      return;
    }
    await _subs.subscribe(
      client: client,
      runtime: _runtime,
      uri: uri,
      binding: binding,
      ownerKey: handle.key,
    );
  }

  Future<void> _onResourceUnsubscribe(String uri) async {
    final client = _client;
    if (client == null) return;
    await _subs.unsubscribe(
      client: client,
      runtime: _runtime,
      uri: uri,
      ownerKey: handle.key,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Runtime teardown fully resets the process-wide ThemeManager
    // (MCPUIRuntime.destroy → ThemeManager.instance.reset()), so the theme
    // ownership tag must drop with it — otherwise a SAME-app re-entry skips
    // rebaseline over the bare default (live pattern: re-open of the same
    // app broken, detour through another app healed).
    if (_themeStateOwner == handle.toString()) _themeStateOwner = null;
    final client = _client;
    if (client != null) {
      await _subs.unsubscribeAllFor(
        client: client,
        runtime: _runtime,
        ownerKey: handle.key,
      );
    }
    await _runtimeManager.removeRuntime(handle);
    // Tear down the JS tool surface — unregister every dispatcher entry
    // and dispose the worker isolate.
    for (final name in _jsToolNames) {
      _tools.unregisterInProcessTool(name);
    }
    final js = _jsRuntime;
    if (js != null) {
      try {
        await js.dispose();
      } catch (e) {
        _logger.warn('JsToolRuntime dispose threw', null, e);
      }
    }
    if (_onClose != null) {
      try {
        await _onClose!();
      } catch (e) {
        _logger.warn('AppSession onClose hook threw', null, e);
      }
    }
  }
}
