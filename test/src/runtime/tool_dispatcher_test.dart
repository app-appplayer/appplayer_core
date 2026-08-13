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

  group('ToolDispatcher in-process path', () {
    test('register + call returns the handler result', () async {
      final d = ToolDispatcher();
      d.registerInProcessTool('echo', (p) async => p);
      final out = await d.callInProcess('echo', const {'k': 1});
      expect(out, const {'k': 1});
    });

    test('registerInProcessTools adds every entry at once', () async {
      final d = ToolDispatcher();
      d.registerInProcessTools(<String, InProcessToolHandler>{
        'a': (_) async => 'A',
        'b': (_) async => 'B',
      });
      expect(d.inProcessToolNames.toSet(), {'a', 'b'});
      expect(await d.callInProcess('a', const {}), 'A');
      expect(await d.callInProcess('b', const {}), 'B');
    });

    test('register overwrites a previous handler bound to the same name',
        () async {
      final d = ToolDispatcher();
      d.registerInProcessTool('t', (_) async => 'v1');
      d.registerInProcessTool('t', (_) async => 'v2');
      expect(await d.callInProcess('t', const {}), 'v2');
    });

    test('unregister removes the handler from the in-process map', () async {
      final d = ToolDispatcher();
      d.registerInProcessTool('t', (_) async => 1);
      d.unregisterInProcessTool('t');
      expect(d.inProcessToolNames, isEmpty);
      await expectLater(
        d.callInProcess('t', const {}),
        throwsA(isA<ToolNotFoundException>()),
      );
    });

    test('routerFor(null): an unregistered tool fails instead of returning null',
        () async {
      // A null return reads as a successful call with no payload one layer up,
      // so a misspelled tool name reached `onSuccess` and the document carried
      // on as though the call had happened.
      final dispatcher = ToolDispatcher();
      final seen = <String>[];
      final route = dispatcher.routerFor(null, onNoClient: seen.add);

      await expectLater(
        route('does.not.exist', const <String, dynamic>{}),
        throwsA(isA<ToolExecutionException>()),
      );
      expect(seen, ['does.not.exist']);
    });

    test('routerFor(null): a registered in-process tool still answers',
        () async {
      final dispatcher = ToolDispatcher();
      dispatcher.registerInProcessTools({'local.echo': (args) async => {'ok': true}});
      final route = dispatcher.routerFor(null);

      expect(await route('local.echo', const <String, dynamic>{}),
          {'ok': true});
    });

    test('callInProcess unknown tool → ToolNotFoundException', () async {
      final d = ToolDispatcher();
      await expectLater(
        d.callInProcess('missing', const {}),
        throwsA(isA<ToolNotFoundException>()),
      );
    });

    test('callInProcess handler throwing → ToolExecutionException',
        () async {
      final d = ToolDispatcher();
      d.registerInProcessTool('boom', (_) async => throw StateError('x'));
      await expectLater(
        d.callInProcess('boom', const {}),
        throwsA(isA<ToolExecutionException>()),
      );
    });

    test('call() short-circuits to in-process when tool is registered',
        () async {
      final d = ToolDispatcher();
      d.registerInProcessTool('local', (_) async => 'inproc');
      // No `when()` stubbed on `client` → if the dispatcher fell through
      // to listTools / callTool, the call would explode with a mocktail
      // missing-stub error. A clean return proves the short-circuit.
      final out = await d.call(
        client: client,
        tool: 'local',
        params: const {},
      );
      expect(out, 'inproc');
    });

    test('call() in-process throwing → ToolExecutionException', () async {
      final d = ToolDispatcher();
      d.registerInProcessTool('boom', (_) async => throw StateError('x'));
      await expectLater(
        d.call(client: client, tool: 'boom', params: const {}),
        throwsA(isA<ToolExecutionException>()),
      );
    });

    test('router marks an in-process {ok:false} payload as an error result',
        () async {
      final d = ToolDispatcher();
      d.registerInProcessTool(
        'mcp.connect',
        (_) async => const <String, dynamic>{
          'ok': false,
          'code': 'mcp.error',
          'error': 'connect timed out after 15000ms',
        },
      );
      final router = d.routerFor(null);
      final out = await router('mcp.connect', const {});

      expect(out, isA<Map<String, dynamic>>());
      expect((out as Map)['isError'], isTrue);
      final text = (out['content'] as List).single['text'] as String;
      expect(text, contains('connect timed out'));
      expect(text, contains('mcp.error'));
    });

    test('router leaves an in-process {ok:true} payload untouched', () async {
      final d = ToolDispatcher();
      d.registerInProcessTool(
        'mcp.connect',
        (_) async => const <String, dynamic>{'ok': true, 'id': 'node'},
      );
      final out = await d.routerFor(null)('mcp.connect', const {});
      expect(out, const <String, dynamic>{'ok': true, 'id': 'node'});
    });

    test('call() marks an in-process {ok:false} payload the same way',
        () async {
      final d = ToolDispatcher();
      d.registerInProcessTool(
        'mcp.call_tool',
        (_) async => const <String, dynamic>{
          'ok': false,
          'code': 'mcp.not_connected',
          'error': 'no connection: node',
        },
      );
      final out = await d.call(
        client: client,
        tool: 'mcp.call_tool',
        params: const {},
      );
      expect((out as Map)['isError'], isTrue);
    });

    test('callInProcess keeps the raw payload for JS atoms', () async {
      final d = ToolDispatcher();
      d.registerInProcessTool(
        'mcp.connect',
        (_) async => const <String, dynamic>{'ok': false, 'code': 'x'},
      );
      final out = await d.callInProcess('mcp.connect', const {});
      expect(out, const <String, dynamic>{'ok': false, 'code': 'x'});
    });

    test('inProcessToolNames returns an unmodifiable view', () {
      final d = ToolDispatcher();
      d.registerInProcessTool('a', (_) async => null);
      final names = d.inProcessToolNames;
      expect(() => names.add('z'), throwsA(isA<UnsupportedError>()));
    });
  });
}
