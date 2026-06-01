import 'package:appplayer_core/internals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('McpAtom', () {
    late ToolDispatcher dispatcher;
    late McpAtom atom;

    setUp(() {
      dispatcher = ToolDispatcher();
      atom = McpAtom(dispatcher);
    });

    test('key + verb names', () {
      expect(atom.key, 'mcp');
      expect(
        atom.verbs.map((v) => v.name).toList(),
        ['callTool', 'listTools'],
      );
    });

    test('callTool returns {isError: false, body} on success', () async {
      dispatcher.registerInProcessTool('echo', (params) async => params);
      final out = await atom.dispatch('callTool', [
        'echo',
        <String, dynamic>{'k': 1},
      ]) as Map;
      expect(out['isError'], isFalse);
      expect(out['body'], <String, dynamic>{'k': 1});
    });

    test('callTool defaults args to {} when omitted', () async {
      Map<String, dynamic>? captured;
      dispatcher.registerInProcessTool('echo', (params) async {
        captured = params;
        return null;
      });
      await atom.dispatch('callTool', ['echo']);
      expect(captured, <String, dynamic>{});
    });

    test('callTool wraps thrown exception as {isError: true, body.error}',
        () async {
      dispatcher.registerInProcessTool(
        'boom',
        (_) async => throw StateError('kaboom'),
      );
      final out = await atom.dispatch('callTool', ['boom', const {}]) as Map;
      expect(out['isError'], isTrue);
      expect((out['body'] as Map)['error'], contains('kaboom'));
    });

    test('callTool with no args throws ArgumentError', () async {
      expect(
        () => atom.dispatch('callTool', const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('callTool rejects non-String toolName', () async {
      expect(
        () => atom.dispatch('callTool', [42]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('callTool rejects empty toolName', () async {
      expect(
        () => atom.dispatch('callTool', ['']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('callTool rejects non-Map args', () async {
      expect(
        () => atom.dispatch('callTool', ['echo', 'not-a-map']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('listTools returns the registered names', () async {
      dispatcher.registerInProcessTools(<String, InProcessToolHandler>{
        'a': (_) async => null,
        'b': (_) async => null,
      });
      final names = await atom.dispatch('listTools', const []) as List;
      expect(names.toSet(), {'a', 'b'});
    });

    test('unknown verb throws ArgumentError', () async {
      expect(
        () => atom.dispatch('nope', const []),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
