import 'dart:convert';

import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../exceptions.dart';
import '../logging/logger.dart';

/// In-process tool handler. Returns the parsed JSON value (or `null`)
/// that the runtime applies auto-merge against — exactly the
/// shape an MCP `callTool` text response would decode to.
typedef InProcessToolHandler = Future<dynamic> Function(
  Map<String, dynamic> params,
);

/// Dispatches MCP tool calls and returns the parsed JSON response so the
/// runtime can apply auto-merge against its own state. Host
/// responsibilities here are limited to MCP forwarding, listTools-based
/// existence checks (for clearer error messaging), and exception modelling
/// (MOD-RUNTIME-003, FR-TOOL-001~005).
///
/// In-process resolver hook — tools registered by the core (or by the
/// host) run directly without an external MCP server call. The brain_kernel
/// standard tool surface (`bk.*`) is registered through this path so
/// every facade call resolves in-process with zero round-trip cost.
class ToolDispatcher {
  ToolDispatcher({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;
  final Map<String, InProcessToolHandler> _inProcess =
      <String, InProcessToolHandler>{};

  /// Register a single tool. Overwrites any previous handler bound to
  /// the same name, since hosts may intentionally replace a wrapper.
  void registerInProcessTool(String name, InProcessToolHandler handler) {
    _inProcess[name] = handler;
  }

  /// Register multiple tools at once.
  void registerInProcessTools(Map<String, InProcessToolHandler> tools) {
    _inProcess.addAll(tools);
  }

  /// Unregister a tool — used when the tool surface changes
  /// dynamically.
  void unregisterInProcessTool(String name) {
    _inProcess.remove(name);
  }

  /// Names of every currently-registered in-process tool.
  List<String> get inProcessToolNames => List.unmodifiable(_inProcess.keys);

  /// The registered name [tool] reaches when called from inside [scope].
  ///
  /// A bundle's own tools are registered as `<bundleId>.<name>` (platform
  /// spec 04 name isolation), and the bundle calls them by the name it
  /// declared: the id it runs under can be chosen at install, so it cannot
  /// write its own full name. Inside a bundle the short name is tried in that
  /// bundle's namespace first; the full name, and any tool outside the bundle,
  /// resolve as written. Null when nothing is registered under either.
  String? resolveInProcess(String tool, {String? scope}) {
    if (scope != null && scope.isNotEmpty) {
      final own = '$scope.$tool';
      if (_inProcess.containsKey(own)) return own;
    }
    return _inProcess.containsKey(tool) ? tool : null;
  }

  /// Dispatch a registered tool entirely in-process, with no external
  /// MCP client involved. Used by JS atoms such as `host.mcp.callTool`.
  /// Throws `ToolNotFoundException` for unregistered tool names.
  Future<dynamic> callInProcess(
    String tool,
    Map<String, dynamic> params, {
    String? scope,
  }) async {
    final name = resolveInProcess(tool, scope: scope);
    final handler = name == null ? null : _inProcess[name];
    if (handler == null) {
      throw ToolNotFoundException(tool, _inProcess.keys.toList());
    }
    try {
      return await handler(params);
    } catch (e, st) {
      _logger.logError('In-process tool failed', e, st, {'tool': tool});
      throw ToolExecutionException(tool, cause: e);
    }
  }

  /// An in-process result in the shape the runtime reads failure from.
  ///
  /// A kernel tool reports failure in its payload (`{ok: false, code, error}`)
  /// rather than by throwing. The external endpoint marks that payload
  /// `isError` on the way out; the in-process path has to mark it too, or the
  /// same call succeeds on one route and fails on the other. Without the mark
  /// the runtime sees an ordinary payload and fires `onSuccess` for a call
  /// that did not happen.
  Future<dynamic> _callInProcessForRuntime(
    String tool,
    Map<String, dynamic> params, {
    String? scope,
  }) async {
    final result = await callInProcess(tool, params, scope: scope);
    if (result is Map && result['ok'] == false) {
      return <String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': jsonEncode(result)},
        ],
        'isError': true,
      };
    }
    return result;
  }

  /// The routing a host hands the runtime as `onToolCall`: an in-process tool
  /// when there is no client, the full dispatch when there is.
  ///
  /// Shared because it is needed at two moments — before `initialize`, so a
  /// definition-level `onInit` tool call has somewhere to land (MCP UI DSL
  /// §1.5.2 fires that hook ahead of the first render), and again at
  /// `buildUI` for everything after. Two copies of it would drift.
  ///
  /// [scope] is the bundle the calls come from, so its own tools answer to the
  /// names it declared ([resolveInProcess]).
  Future<dynamic> Function(String, Map<String, dynamic>) routerFor(
    Client? client, {
    void Function(String tool)? onNoClient,
    String? scope,
  }) {
    return (String tool, Map<String, dynamic> params) async {
      if (client == null) {
        if (resolveInProcess(tool, scope: scope) != null) {
          return _callInProcessForRuntime(tool, params, scope: scope);
        }
        onNoClient?.call(tool);
        // Not `null`: the runtime reads a null return as a successful call
        // with no payload, so a misspelled tool name came back as `onSuccess`
        // and the document carried on as though the call had happened.
        throw ToolExecutionException(
          tool,
          cause: StateError('no tool named "$tool" and no connected server'),
        );
      }
      return call(client: client, tool: tool, params: params, scope: scope);
    };
  }

  Future<dynamic> call({
    required Client client,
    required String tool,
    required Map<String, dynamic> params,
    String? scope,
  }) async {
    _logger.debug('Tool call', {'tool': tool, 'params': params});

    // Try in-process first. If the tool is registered we skip the
    // external MCP forward and resolve it directly.
    if (resolveInProcess(tool, scope: scope) != null) {
      return _callInProcessForRuntime(tool, params, scope: scope);
    }

    final List<Tool> tools;
    try {
      tools = await client.listTools();
    } catch (e, st) {
      _logger.logError('listTools failed', e, st, {'tool': tool});
      throw ToolExecutionException(tool, cause: e);
    }

    if (!tools.any((t) => t.name == tool)) {
      throw ToolNotFoundException(
        tool,
        tools.map((t) => t.name).toList(),
      );
    }

    final CallToolResult result;
    try {
      result = await client.callTool(tool, params);
    } catch (e, st) {
      _logger.logError('callTool failed', e, st, {'tool': tool});
      throw ToolExecutionException(tool, cause: e);
    }

    _logger
        .debug('Tool result', {'tool': tool, 'items': result.content.length});

    if (result.content.isEmpty) return null;
    final first = result.content.first;
    if (first is! TextContent) return null;

    try {
      return jsonDecode(first.text);
    } catch (e) {
      _logger.warn(
          'Failed to parse tool response',
          {
            'tool': tool,
            'text': first.text,
          },
          e);
      return null;
    }
  }
}
