/// A bundle's `cloud` and `mcp` tools answer what the spec says they answer,
/// every way they can fail is named rather than softened into a value, and an
/// `mcp` tool rides the host's client host — one connection per server,
/// reused — instead of dialling its own.
library;

import 'dart:convert';

import 'package:appplayer_core/src/bundle/bundle_tool_handlers.dart';
import 'package:brain_kernel/brain_kernel.dart'
    show
        KernelClientConnection,
        KernelClientHost,
        KernelTextContent,
        KernelToolResult,
        KernelTransportKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

class _FakeConnection implements KernelClientConnection {
  _FakeConnection(this.id);

  @override
  final String id;

  bool closed = false;
  final List<(String, Map<String, dynamic>)> calls = [];

  @override
  bool get isConnected => !closed;

  @override
  Future<KernelToolResult> callTool(String name, Map<String, dynamic> args) async {
    calls.add((name, args));
    return KernelToolResult(
      content: [KernelTextContent(text: jsonEncode({'tool': name, 'args': args}))],
      isError: false,
    );
  }

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClientHost implements KernelClientHost {
  final Map<String, _FakeConnection> opened = {};
  final List<(String, KernelTransportKind, String?)> dials = [];
  final List<Map<String, dynamic>?> dialOptions = [];

  @override
  Future<KernelClientConnection> connect({
    required String id,
    required KernelTransportKind transport,
    String? endpoint,
    Map<String, dynamic>? options,
  }) async {
    final existing = opened[id];
    if (existing != null && existing.isConnected) return existing;
    dials.add((id, transport, endpoint));
    dialOptions.add(options);
    return opened[id] = _FakeConnection(id);
  }

  @override
  Iterable<KernelClientConnection> get connections => opened.values;

  @override
  Future<void> shutdown() async {}
}

void main() {
  group('cloud', () {
    late List<http.Request> sent;

    http.Client answering(int status, String body) =>
        http_testing.MockClient((request) async {
          sent.add(request);
          return http.Response(body, status);
        });

    setUp(() => sent = []);

    test('POSTs the input as JSON and answers the parsed body', () async {
      final handler = cloudToolHandler(
        'weather.lookup',
        {'url': 'https://api.example.com/weather'},
        client: answering(200, '{"temp": 21, "unit": "C"}'),
      );

      final result = await handler({'city': 'Seoul'});

      expect(result, {'temp': 21, 'unit': 'C'});
      expect(sent.single.method, 'POST');
      expect(sent.single.url.toString(), 'https://api.example.com/weather');
      expect(sent.single.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(sent.single.body), {'city': 'Seoul'});
    });

    test('an empty body is an empty object', () async {
      final handler = cloudToolHandler('t', {'url': 'https://x.example/t'},
          client: answering(200, ''));
      expect(await handler({}), <String, dynamic>{});
    });

    test('a non-2xx status fails with the status', () async {
      final handler = cloudToolHandler('t', {'url': 'https://x.example/t'},
          client: answering(503, 'down'));
      await expectLater(handler({}),
          throwsA(isA<StateError>().having((e) => e.message, 'm', contains('503'))));
    });

    test('a body that is not JSON fails instead of answering {}', () async {
      final handler = cloudToolHandler('t', {'url': 'https://x.example/t'},
          client: answering(200, '<html>oops</html>'));
      await expectLater(handler({}),
          throwsA(isA<StateError>().having((e) => e.message, 'm', contains('not JSON'))));
    });

    test('a URL that is not https is refused before any request', () async {
      for (final url in ['http://x.example/t', 'ftp://x/t', '', null, 'nonsense']) {
        final handler = cloudToolHandler('t', {'url': url},
            client: answering(200, '{}'));
        await expectLater(handler({}), throwsStateError, reason: '$url');
      }
      expect(sent, isEmpty);
    });
  });

  group('mcp', () {
    late _FakeClientHost host;

    setUp(() => host = _FakeClientHost());

    Future<dynamic> Function(Map<String, dynamic>) handlerFor(
      String name,
      Map<String, dynamic> target, {
      String connectionId = 'bundle:works.search:https://mcp.example.com',
    }) =>
        mcpToolHandler(name, target,
            clientHost: () => host, connectionId: connectionId);

    test('calls target.tool through the client host and answers a CallToolResult',
        () async {
      final handler = handlerFor('remote.search',
          {'transport': 'http', 'url': 'https://mcp.example.com', 'tool': 'search'});

      final result = await handler({'q': 'lamp'}) as Map<String, dynamic>;

      expect(result['isError'], isFalse);
      final text = (result['content'] as List).single as Map<String, dynamic>;
      expect(text['type'], 'text');
      expect(jsonDecode(text['text'] as String), {
        'tool': 'search',
        'args': {'q': 'lamp'},
      });
      expect(host.dials.single, (
        'bundle:works.search:https://mcp.example.com',
        KernelTransportKind.streamableHttp,
        'https://mcp.example.com',
      ));
    });

    test('without target.tool the entry\'s own name is called', () async {
      final handler = handlerFor(
          'remote.search', {'transport': 'http', 'url': 'https://mcp.example.com'});
      await handler({});
      expect(host.opened.values.single.calls.single.$1, 'remote.search');
    });

    test('calls and tools naming the same server share one connection', () async {
      final search = handlerFor('remote.search',
          {'transport': 'http', 'url': 'https://mcp.example.com', 'tool': 'search'});
      final fetch = handlerFor('remote.fetch',
          {'transport': 'http', 'url': 'https://mcp.example.com', 'tool': 'fetch'});

      await search({'q': 1});
      await search({'q': 2});
      await fetch({'id': 3});

      expect(host.dials, hasLength(1));
      expect(host.opened.values.single.calls.map((c) => c.$1),
          ['search', 'search', 'fetch']);
    });

    test('a closed connection is reopened on the next call', () async {
      final handler = handlerFor(
          'remote.search', {'transport': 'http', 'url': 'https://mcp.example.com'});
      await handler({});
      await host.opened.values.single.close();
      await handler({});
      expect(host.dials, hasLength(2));
    });

    test('stdio on a desktop starts through the client host with its command line',
        () async {
      const target = <String, dynamic>{
        'transport': 'stdio',
        'command': 'npx',
        'args': ['-y', '@modelcontextprotocol/server-github'],
        'tool': 'create_issue',
      };
      final id = mcpConnectionId('works.gh', target);
      final handler = mcpToolHandler('gh.issue', target,
          clientHost: () => host,
          connectionId: id,
          canRunProcesses: () => true);

      await handler({'title': 't'});

      expect(id, 'bundle:works.gh:stdio:npx -y @modelcontextprotocol/server-github');
      expect(host.dials.single, (id, KernelTransportKind.stdio, null));
      expect(host.dialOptions.single, {
        'command': 'npx',
        'args': ['-y', '@modelcontextprotocol/server-github'],
      });
      expect(host.opened.values.single.calls.single.$1, 'create_issue');
    });

    test('stdio where no process can run is refused by name, nothing is dialled',
        () async {
      final handler = mcpToolHandler(
          'gh.issue', {'transport': 'stdio', 'command': 'npx'},
          clientHost: () => host,
          connectionId: 'x',
          canRunProcesses: () => false);
      await expectLater(handler({}),
          throwsA(isA<StateError>().having((e) => e.message, 'm', contains('stdio'))));
      expect(host.dials, isEmpty);
    });

    test('stdio without a command is refused, nothing is dialled', () async {
      final handler = mcpToolHandler('gh.issue', {'transport': 'stdio'},
          clientHost: () => host,
          connectionId: 'x',
          canRunProcesses: () => true);
      await expectLater(handler({}),
          throwsA(isA<StateError>().having((e) => e.message, 'm', contains('command'))));
      expect(host.dials, isEmpty);
    });

    test('an http server is named by its url', () {
      expect(
        mcpConnectionId('works.search', {'transport': 'http', 'url': 'https://mcp.example.com'}),
        'bundle:works.search:https://mcp.example.com',
      );
    });

    test('an http target without a url is refused', () async {
      final handler = handlerFor('t', {'transport': 'http'});
      await expectLater(handler({}), throwsStateError);
      expect(host.dials, isEmpty);
    });

    test('a host without an outbound client says so', () async {
      final handler = mcpToolHandler(
        't',
        {'transport': 'http', 'url': 'https://mcp.example.com'},
        clientHost: () => null,
        connectionId: 'x',
      );
      await expectLater(handler({}),
          throwsA(isA<StateError>().having((e) => e.message, 'm', contains('no outbound'))));
    });
  });
}
