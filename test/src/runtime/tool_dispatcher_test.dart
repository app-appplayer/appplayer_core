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
  late MockMCPUIRuntime runtime;
  late MockStateManager state;

  setUp(() {
    client = MockClient();
    runtime = MockMCPUIRuntime();
    state = MockStateManager();
    when(() => runtime.stateManager).thenReturn(state);
    when(() => state.set(any(), any())).thenReturn(null);
  });

  group('ToolDispatcher (MOD-RUNTIME-003)', () {
    test('TC-TOOL-001: normal call sets state', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('incr')]);
      when(() => client.callTool('incr', any())).thenAnswer(
        (_) async =>
            CallToolResult([const TextContent(text: '{"count":5}')]),
      );

      await ToolDispatcher().call(
        client: client,
        runtime: runtime,
        tool: 'incr',
        params: const {},
      );

      verify(() => state.set('count', 5)).called(1);
    });

    test('TC-TOOL-002: tool not found', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('other')]);
      await expectLater(
        ToolDispatcher().call(
          client: client,
          runtime: runtime,
          tool: 'missing',
          params: const {},
        ),
        throwsA(isA<ToolNotFoundException>()),
      );
    });

    test('TC-TOOL-003: multiple state keys set', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('t')]);
      when(() => client.callTool('t', any())).thenAnswer((_) async =>
          CallToolResult([const TextContent(text: '{"a":1,"b":"x"}')]));
      await ToolDispatcher().call(
        client: client,
        runtime: runtime,
        tool: 't',
        params: const {},
      );
      verify(() => state.set('a', 1)).called(1);
      verify(() => state.set('b', 'x')).called(1);
    });

    test('TC-TOOL-004: empty content — no state update', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('t')]);
      when(() => client.callTool('t', any()))
          .thenAnswer((_) async => const CallToolResult([]));
      await ToolDispatcher().call(
        client: client,
        runtime: runtime,
        tool: 't',
        params: const {},
      );
      verifyNever(() => state.set(any(), any()));
    });

    test('TC-TOOL-006: parse failure — logged, no throw', () async {
      when(() => client.listTools())
          .thenAnswer((_) async => [_tool('t')]);
      when(() => client.callTool('t', any())).thenAnswer((_) async =>
          CallToolResult([const TextContent(text: 'not-json')]));
      await ToolDispatcher().call(
        client: client,
        runtime: runtime,
        tool: 't',
        params: const {},
      );
      verifyNever(() => state.set(any(), any()));
    });

    test('TC-TOOL-007: listTools failure → ToolExecutionException',
        () async {
      when(() => client.listTools()).thenThrow(StateError('down'));
      await expectLater(
        ToolDispatcher().call(
          client: client,
          runtime: runtime,
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
          runtime: runtime,
          tool: 't',
          params: const {},
        ),
        throwsA(isA<ToolExecutionException>()),
      );
    });
  });
}
