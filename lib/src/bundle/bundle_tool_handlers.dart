/// Handlers for a bundle's `kind: cloud` and `kind: mcp` tools (bundle spec
/// §4.5, §4.6) — the tools a js tool reaches through `host.mcp.callTool` and a
/// document reaches through a tool action.
///
/// The same bundle runs on the marketplace cloud runner and in this host, and
/// a user picks which. A tool that runs in one and fails in the other makes
/// that choice change what the app does, so both follow the spec's shapes:
/// `cloud` answers the endpoint's JSON body, `mcp` answers the remote
/// `CallToolResult`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../connection/connection_manager.dart' show ClientConnector;

/// `kind: cloud` — POST the input as JSON to `target.url`, answer the parsed
/// body.
///
/// Refused rather than softened: a non-HTTPS URL, a non-2xx status, and a body
/// that is not JSON each fail the call with that reason. An empty result in
/// their place is indistinguishable from an endpoint that had nothing to say.
Future<dynamic> Function(Map<String, dynamic>) cloudToolHandler(
  String toolName,
  Map<String, dynamic> target, {
  http.Client? client,
}) {
  return (params) async {
    final url = target['url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError(
          'cloud tool $toolName needs an https target.url, got: $url');
    }
    final http.Client c = client ?? http.Client();
    try {
      final response = await c.post(
        uri,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(params),
      );
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw StateError('cloud tool $toolName failed: '
            '${response.statusCode} ${response.reasonPhrase ?? ''}'.trim());
      }
      final body = response.body;
      if (body.trim().isEmpty) return <String, dynamic>{};
      try {
        return jsonDecode(body);
      } on FormatException {
        throw StateError('cloud tool $toolName answered a body that is not '
            'JSON (${body.length} bytes)');
      }
    } finally {
      if (client == null) c.close();
    }
  };
}

/// `kind: mcp` — call the remote tool (`target.tool`, or this entry's own
/// name) on the MCP server `target` names, answer its `CallToolResult`.
///
/// One connection per call, closed after — the same shape the cloud runner
/// uses, so a server that serves one client at a time is not held open.
/// `transport: stdio` starts a local process; this host does not run one for a
/// bundle, and says so.
Future<dynamic> Function(Map<String, dynamic>) mcpToolHandler(
  String toolName,
  Map<String, dynamic> target, {
  required ClientConnector connect,
}) {
  return (params) async {
    final transport = target['transport'];
    if (transport == 'stdio') {
      throw StateError('mcp tool $toolName uses transport stdio, which starts '
          'a local process; this host does not run processes for a bundle');
    }
    final url = target['url'];
    if (transport != 'http' || url is! String || url.isEmpty) {
      throw StateError(
          'mcp tool $toolName needs { "transport": "http", "url" }');
    }
    final remote = target['tool'] is String && (target['tool'] as String).isNotEmpty
        ? target['tool'] as String
        : toolName;
    final client = await connect(TransportConfig.streamableHttp(
      baseUrl: url,
      terminateOnClose: true,
    ));
    try {
      final result = await client.callTool(remote, params);
      return <String, dynamic>{
        'content': [for (final c in result.content) c.toJson()],
        if (result.structuredContent != null)
          'structuredContent': result.structuredContent,
        'isError': result.isError ?? false,
      };
    } finally {
      client.disconnect();
    }
  };
}
