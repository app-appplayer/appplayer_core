/// Handlers for a bundle's `kind: cloud` and `kind: mcp` tools — the tools a
/// js tool reaches through `host.mcp.callTool` and a document reaches through
/// a tool action.
///
/// The same bundle runs on the marketplace cloud runner and in this host, and
/// a user picks which. A tool that runs in one and fails in the other makes
/// that choice change what the app does, so both answer the same shapes:
/// `cloud` answers the endpoint's JSON body, `mcp` answers the remote
/// `CallToolResult`.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart'
    show
        KernelClientHost,
        KernelContent,
        KernelImageContent,
        KernelTextContent,
        KernelTransportKind;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:http/http.dart' as http;

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
/// The connection belongs to the host's outbound client host, under
/// [connectionId] — one per server per bundle. Every tool that names the
/// server reuses it, and the host closes it with the bundle's session. A
/// private connection per call would be a second connection registry beside
/// the client host's, and a server that serves one peer at a time would reset
/// the host's other link to it.
///
/// `transport: stdio` starts a local process. A desktop host runs it through
/// the same client host; a host that cannot run one — a phone, a browser —
/// refuses the call with that reason ([canRunProcesses]).
Future<dynamic> Function(Map<String, dynamic>) mcpToolHandler(
  String toolName,
  Map<String, dynamic> target, {
  required KernelClientHost? Function() clientHost,
  required String connectionId,
  bool Function() canRunProcesses = hostRunsLocalProcesses,
}) {
  return (params) async {
    final transport = target['transport'];
    final KernelTransportKind kind;
    String? endpoint;
    Map<String, dynamic>? options;
    if (transport == 'stdio') {
      final command = target['command'];
      if (command is! String || command.isEmpty) {
        throw StateError(
            'mcp tool $toolName needs { "transport": "stdio", "command" }');
      }
      if (!canRunProcesses()) {
        throw StateError('mcp tool $toolName uses transport stdio, which starts '
            'a local process; this device cannot run one');
      }
      final args = target['args'];
      kind = KernelTransportKind.stdio;
      options = <String, dynamic>{
        'command': command,
        'args': args is List ? [for (final a in args) '$a'] : const <String>[],
      };
    } else {
      final url = target['url'];
      if (transport != 'http' || url is! String || url.isEmpty) {
        throw StateError(
            'mcp tool $toolName needs { "transport": "http", "url" }');
      }
      kind = KernelTransportKind.streamableHttp;
      endpoint = url;
    }
    final host = clientHost();
    if (host == null) {
      throw StateError('mcp tool $toolName cannot run: this host has no '
          'outbound MCP client');
    }
    final remote =
        target['tool'] is String && (target['tool'] as String).isNotEmpty
            ? target['tool'] as String
            : toolName;
    final connection = await host.connect(
      id: connectionId,
      transport: kind,
      endpoint: endpoint,
      options: options,
    );
    final result = await connection.callTool(remote, params);
    return <String, dynamic>{
      'content': [for (final c in result.content) _contentJson(c)],
      'isError': result.isError ?? false,
    };
  };
}

/// Whether this device can start a local process for a `stdio` MCP server:
/// desktops can; phones and browsers cannot.
bool hostRunsLocalProcesses() {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux =>
      true,
    _ => false,
  };
}

/// The client-host connection id for a bundle's `kind: mcp` [target] — one
/// per server per bundle. A stdio server is named by its command line, since
/// it has no URL.
String mcpConnectionId(String bundleId, Map<String, dynamic> target) {
  if (target['transport'] == 'stdio') {
    final args = target['args'];
    final argv = [
      '${target['command']}',
      if (args is List) ...[for (final a in args) '$a'],
    ].join(' ');
    return 'bundle:$bundleId:stdio:$argv';
  }
  return 'bundle:$bundleId:${target['url']}';
}

Map<String, dynamic> _contentJson(KernelContent content) => switch (content) {
      KernelTextContent(:final text) => <String, dynamic>{
          'type': 'text',
          'text': text,
        },
      KernelImageContent(:final data, :final mimeType) => <String, dynamic>{
          'type': 'image',
          'data': data,
          'mimeType': mimeType,
        },
    };
