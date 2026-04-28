import 'dart:convert';

import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../exceptions.dart';
import '../logging/logger.dart';

/// Dispatches MCP tool calls and folds their JSON responses into runtime state
/// (MOD-RUNTIME-003, FR-TOOL-001~005).
class ToolDispatcher {
  ToolDispatcher({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;

  Future<void> call({
    required Client client,
    required MCPUIRuntime runtime,
    required String tool,
    required Map<String, dynamic> params,
  }) async {
    _logger.debug('Tool call', {'tool': tool, 'params': params});

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

    if (result.content.isEmpty) return;
    final first = result.content.first;
    if (first is! TextContent) return;

    try {
      final decoded = jsonDecode(first.text);
      if (decoded is! Map<String, dynamic>) return;
      decoded.forEach((key, value) {
        runtime.stateManager.set(key, value);
        _logger.debug('State updated', {'key': key});
      });
    } catch (e) {
      _logger.warn('Failed to parse tool response', {
        'tool': tool,
        'text': first.text,
      }, e);
    }
  }
}
