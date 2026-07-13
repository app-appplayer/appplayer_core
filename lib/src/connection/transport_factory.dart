import 'package:mcp_client/mcp_client.dart';

import '../model/server_config.dart';

/// Translates [ServerConfig] into an `mcp_client.TransportConfig`
/// (MOD-CONN-002, FR-CONN-009).
///
/// Adding a new transport type requires changing only this module
/// (NFR-EXT-004).
class TransportFactory {
  const TransportFactory();

  TransportConfig create(ServerConfig server) {
    final cfg = server.transportConfig;

    switch (server.transportType) {
      case TransportType.stdio:
        final command = cfg['command'];
        if (command is! String) {
          throw ArgumentError(
            'stdio transport requires "command" string field',
          );
        }
        return TransportConfig.stdio(
          command: command,
          arguments:
              (cfg['arguments'] as List<dynamic>?)?.cast<String>() ??
                  const <String>[],
          workingDirectory: cfg['workingDirectory'] as String?,
        );

      case TransportType.sse:
        final serverUrl = cfg['serverUrl'];
        if (serverUrl is! String) {
          throw ArgumentError(
            'sse transport requires "serverUrl" string field',
          );
        }
        final heartbeatSeconds = cfg['heartbeatInterval'] as int?;
        return TransportConfig.sse(
          serverUrl: serverUrl,
          bearerToken: cfg['bearerToken'] as String?,
          enableCompression:
              cfg['enableCompression'] as bool? ?? false,
          heartbeatInterval: heartbeatSeconds != null
              ? Duration(seconds: heartbeatSeconds)
              : null,
        );

      case TransportType.streamableHttp:
        final baseUrl = cfg['baseUrl'];
        if (baseUrl is! String) {
          throw ArgumentError(
            'streamableHttp transport requires "baseUrl" string field',
          );
        }
        final timeoutSeconds = cfg['timeout'] as int?;
        // Credential wiring. `accessToken` rides the MCP-standard
        // `Authorization: Bearer` header (mirrors the sse branch's
        // bearerToken); `headers` passes through verbatim for servers with a
        // bespoke scheme, and an explicit header wins over the derived one.
        // Dropping the token here was the marketplace service-connect 401
        // (server rejected the unauthenticated handshake → "Transport
        // disconnected").
        final accessToken = cfg['accessToken'] as String?;
        final extraHeaders =
            (cfg['headers'] as Map<dynamic, dynamic>?)?.cast<String, String>();
        final headers = <String, String>{
          if (accessToken != null) 'Authorization': 'Bearer $accessToken',
          ...?extraHeaders,
        };
        return TransportConfig.streamableHttp(
          baseUrl: baseUrl,
          headers: headers.isEmpty ? null : headers,
          useHttp2: cfg['useHttp2'] as bool? ?? true,
          timeout: timeoutSeconds != null
              ? Duration(seconds: timeoutSeconds)
              : null,
          terminateOnClose: false,
        );
    }
  }
}
