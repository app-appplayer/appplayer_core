import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
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

  @override
  Widget buildWidget({
    required BuildContext context,
    VoidCallback? onExit,
  }) {
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

  Future<dynamic> _onToolCall(
      String tool, Map<String, dynamic> params) async {
    final client = _client;
    if (client == null) {
      _logger.warn('session.tool.no_client', {
        'handle': handle.toString(),
        'tool': tool,
      });
      return null;
    }
    return _tools.call(
      client: client,
      tool: tool,
      params: params,
    );
  }

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
