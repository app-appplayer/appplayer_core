/// A bundle's `kind: mcp` tool, end to end over a real wire: the host's
/// outbound client host dials a real streamable HTTP MCP server, and every
/// call the bundle makes rides one connection.
///
/// The widget binding is deliberately not initialized — it replaces the HTTP
/// client with one that answers 400, and this test is about the socket.
library;

import 'dart:io';

import 'package:appplayer_core/src/bundle/bundle_tool_handlers.dart';
import 'package:brain_kernel/mcp_host.dart' show McpClientKernelHost;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_server/mcp_server.dart' as srv;

void main() {
  late srv.Server server;
  late McpClientKernelHost host;
  late String url;
  late int calls;

  setUp(() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    url = 'http://127.0.0.1:$port/mcp';

    final started = await srv.McpServer.createAndStart(
      config: srv.McpServer.simpleConfig(name: 'fixture', version: '0.0.0'),
      transportConfig: srv.TransportConfig.streamableHttp(
        host: '127.0.0.1',
        port: port,
        endpoint: '/mcp',
        isJsonResponseEnabled: true,
      ),
    );
    await started.fold(
      (s) async => server = s,
      (e) async => throw e,
    );

    calls = 0;
    server.addTool(
      name: 'echo',
      description: 'Echo the text back',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'text': <String, dynamic>{'type': 'string'},
        },
      },
      handler: (args) async {
        calls++;
        return srv.CallToolResult(
          content: [srv.TextContent(text: 'echo:${args['text']}')],
        );
      },
    );

    host = McpClientKernelHost();
  });

  tearDown(() async {
    for (final c in host.connections.toList()) {
      await c.close();
    }
    server.dispose();
  });

  Future<dynamic> Function(Map<String, dynamic>) handler() => mcpToolHandler(
        'shout',
        <String, dynamic>{'transport': 'http', 'url': url, 'tool': 'echo'},
        clientHost: () => host,
        connectionId: 'bundle:fixture:$url',
      );

  test('two calls answer over one connection to the server', () async {
    final call = handler();

    final first = await call(<String, dynamic>{'text': 'a'});
    final link = host.connections.single;
    final second = await call(<String, dynamic>{'text': 'b'});

    expect(first, <String, dynamic>{
      'content': [
        <String, dynamic>{'type': 'text', 'text': 'echo:a'},
      ],
      'isError': false,
    });
    expect((second as Map)['content'], [
      <String, dynamic>{'type': 'text', 'text': 'echo:b'},
    ]);
    expect(calls, 2, reason: 'both calls reached the server');
    expect(host.connections, hasLength(1));
    expect(identical(host.connections.single, link), isTrue,
        reason: 'the second call rode the first call\x27s connection');
    expect(link.id, 'bundle:fixture:$url');
  });

  test('a closed connection is dialled again under the same id', () async {
    final call = handler();
    await call(<String, dynamic>{'text': 'a'});
    final link = host.connections.single;

    await link.close();
    expect(link.isConnected, isFalse);

    final again = await call(<String, dynamic>{'text': 'c'});

    expect((again as Map)['content'], [
      <String, dynamic>{'type': 'text', 'text': 'echo:c'},
    ]);
    expect(host.connections, hasLength(1));
    expect(host.connections.single.isConnected, isTrue);
    expect(calls, 2);
  });
}
