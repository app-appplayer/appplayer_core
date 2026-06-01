import 'dart:convert';

import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../exceptions.dart';
import '../logging/logger.dart';

/// In-process tool handler. Returns the parsed JSON value (or `null`)
/// that the runtime applies spec §3.10 auto-merge against — exactly the
/// shape an MCP `callTool` text response would decode to.
typedef InProcessToolHandler = Future<dynamic> Function(
  Map<String, dynamic> params,
);

/// Dispatches MCP tool calls and returns the parsed JSON response so the
/// runtime can apply spec §3.10 auto-merge against its own state. Host
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

  /// Dispatch a registered tool entirely in-process, with no external
  /// MCP client involved. Used by JS atoms such as `host.mcp.callTool`.
  /// Throws `ToolNotFoundException` for unregistered tool names.
  Future<dynamic> callInProcess(
    String tool,
    Map<String, dynamic> params,
  ) async {
    final handler = _inProcess[tool];
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

  Future<dynamic> call({
    required Client client,
    required String tool,
    required Map<String, dynamic> params,
  }) async {
    _logger.debug('Tool call', {'tool': tool, 'params': params});

    // Try in-process first. If the tool is registered we skip the
    // external MCP forward and resolve it directly.
    final inProc = _inProcess[tool];
    if (inProc != null) {
      try {
        return await inProc(params);
      } catch (e, st) {
        _logger.logError('In-process tool failed', e, st, {'tool': tool});
        throw ToolExecutionException(tool, cause: e);
      }
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

    _logger.debug('Tool result',
        {'tool': tool, 'items': result.content.length});

    if (result.content.isEmpty) return null;
    final first = result.content.first;
    if (first is! TextContent) return null;

    try {
      return jsonDecode(first.text);
    } catch (e) {
      _logger.warn('Failed to parse tool response', {
        'tool': tool,
        'text': first.text,
      }, e);
      return null;
    }
  }
}
