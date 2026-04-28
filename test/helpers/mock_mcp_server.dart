import 'dart:convert';

import 'package:mcp_client/mcp_client.dart' hide ConnectionState;
import 'package:mocktail/mocktail.dart';

import 'mocks.dart';

/// Helpers to quickly build a `MockClient` that behaves like a tiny MCP
/// server for integration tests.
class MockMcpServer {
  MockMcpServer() : client = MockClient() {
    when(() => client.disconnect()).thenReturn(null);
    when(() => client.onNotification(any(), any())).thenReturn(null);
  }

  final MockClient client;

  void withResources(List<Resource> resources) {
    when(() => client.listResources()).thenAnswer((_) async => resources);
  }

  void withResourceContent(String uri, Map<String, dynamic> json) {
    when(() => client.readResource(uri)).thenAnswer(
      (_) async => ReadResourceResult(contents: [
        ResourceContentInfo(
          uri: uri,
          mimeType: 'application/json',
          text: jsonEncode(json),
        ),
      ]),
    );
  }

  void withTools(List<String> names) {
    when(() => client.listTools()).thenAnswer((_) async => names
        .map((n) => Tool(name: n, description: '', inputSchema: const {}))
        .toList());
  }

  void withToolResponse(String name, Map<String, dynamic> response) {
    when(() => client.callTool(name, any())).thenAnswer(
      (_) async => CallToolResult([
        TextContent(text: jsonEncode(response)),
      ]),
    );
  }

  void withSubscription() {
    when(() => client.subscribeResource(any()))
        .thenAnswer((_) async {});
    when(() => client.unsubscribeResource(any()))
        .thenAnswer((_) async {});
  }
}

Map<String, dynamic> minimalAppDefinition({String id = 'app-1'}) => {
      'type': 'page',
      'content': {'type': 'text', 'value': 'Hello'},
      'mcpRuntime': {
        'runtime': {
          'id': id,
          'domain': 'test.app',
          'version': '0.0.0',
        },
      },
    };

Map<String, dynamic> minimalSummaryDefinition({String id = 'dev-1'}) => {
      'type': 'page',
      'content': {'type': 'text', 'value': 'summary'},
      'mcpRuntime': {
        'runtime': {
          'id': '$id-summary',
          'domain': 'test.summary',
          'version': '0.0.0',
        },
      },
    };
