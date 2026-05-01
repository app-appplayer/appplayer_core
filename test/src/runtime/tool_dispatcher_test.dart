import 'package:appplayer_core/src/exceptions.dart';
import 'package:appplayer_core/src/runtime/tool_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

Tool _tool(String name) => Tool(
      name: name,
      description: '',
      inputSchema: const {},
    );

void main() {
  late MockClient client;

  setUp(() {
    client = MockClient();
  });

  group('ToolDispatcher (MOD-RUNTIME-003)', () {
    test('TC-TOOL-001: normal call returns decoded JSON map', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('incr')]);
      when(() => client.callTool('incr', any())).thenAnswer(
        (_) async =>
            CallToolResult([const TextContent(text: '{"count":5}')]),
      );

      final result = await ToolDispatcher().call(
        client: client,
        tool: 'incr',
        params: const {},
      );

      expect(result, equals({'count': 5}));
    });

    test('TC-TOOL-002: tool not found', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('other')]);
      await expectLater(
        ToolDispatcher().call(
          client: client,
          tool: 'missing',
          params: const {},
        ),
        throwsA(isA<ToolNotFoundException>()),
      );
    });

    test('TC-TOOL-003: multi-key response returned verbatim', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('t')]);
      when(() => client.callTool('t', any())).thenAnswer((_) async =>
          CallToolResult([const TextContent(text: '{"a":1,"b":"x"}')]));
      final result = await ToolDispatcher().call(
        client: client,
        tool: 't',
        params: const {},
      );
      expect(result, equals({'a': 1, 'b': 'x'}));
    });

    test('TC-TOOL-004: empty content — returns null', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('t')]);
      when(() => client.callTool('t', any()))
          .thenAnswer((_) async => const CallToolResult([]));
      final result = await ToolDispatcher().call(
        client: client,
        tool: 't',
        params: const {},
      );
      expect(result, isNull);
    });

    test('TC-TOOL-006: parse failure — logged, returns null', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('t')]);
      when(() => client.callTool('t', any())).thenAnswer((_) async =>
          CallToolResult([const TextContent(text: 'not-json')]));
      final result = await ToolDispatcher().call(
        client: client,
        tool: 't',
        params: const {},
      );
      expect(result, isNull);
    });

    test('TC-TOOL-007: listTools failure → ToolExecutionException',
        () async {
      when(() => client.listTools()).thenThrow(StateError('down'));
      await expectLater(
        ToolDispatcher().call(
          client: client,
          tool: 't',
          params: const {},
        ),
        throwsA(isA<ToolExecutionException>()),
      );
    });

    test('TC-TOOL-008: callTool failure → ToolExecutionException', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('t')]);
      when(() => client.callTool('t', any())).thenThrow(StateError('boom'));
      await expectLater(
        ToolDispatcher().call(
          client: client,
          tool: 't',
          params: const {},
        ),
        throwsA(isA<ToolExecutionException>()),
      );
    });
  });
}
