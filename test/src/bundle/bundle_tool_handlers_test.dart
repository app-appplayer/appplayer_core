/// A bundle's `cloud` and `mcp` tools answer what the spec says they answer,
/// and every way they can fail is named rather than softened into a value.
library;

import 'dart:convert';

import 'package:appplayer_core/src/bundle/bundle_tool_handlers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mcp_client/mcp_client.dart' hide Logger;
import 'package:mocktail/mocktail.dart';

import '../../helpers/mock_mcp_server.dart';

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
    late MockMcpServer server;
    late List<TransportConfig> dialled;

    setUpAll(() => registerFallbackValue(<String, dynamic>{}));

    setUp(() {
      server = MockMcpServer();
      dialled = [];
    });

    Future<Client> connect(TransportConfig t) async {
      dialled.add(t);
      return server.client;
    }

    test('calls the remote tool and answers its CallToolResult', () async {
      server.withToolResponse('search', {'hits': 3});
      final handler = mcpToolHandler(
        'remote.search',
        {'transport': 'http', 'url': 'https://mcp.example.com', 'tool': 'search'},
        connect: connect,
      );

      final result = await handler({'q': 'lamp'}) as Map<String, dynamic>;

      expect(result['isError'], isFalse);
      final text = (result['content'] as List).single as Map<String, dynamic>;
      expect(jsonDecode(text['text'] as String), {'hits': 3});
      verify(() => server.client.callTool('search', {'q': 'lamp'})).called(1);
      verify(() => server.client.disconnect()).called(1);
      expect(dialled, hasLength(1),
          reason: 'one connection per call, closed after');
    });

    test('without target.tool the entry\'s own name is called', () async {
      server.withToolResponse('remote.search', {'ok': true});
      final handler = mcpToolHandler('remote.search',
          {'transport': 'http', 'url': 'https://mcp.example.com'},
          connect: connect);

      await handler({});

      verify(() => server.client.callTool('remote.search', any())).called(1);
    });

    test('stdio is refused by name, nothing is dialled', () async {
      final handler = mcpToolHandler('gh.issue',
          {'transport': 'stdio', 'command': 'npx'}, connect: connect);
      await expectLater(handler({}),
          throwsA(isA<StateError>().having((e) => e.message, 'm', contains('stdio'))));
      expect(dialled, isEmpty);
    });

    test('an http target without a url is refused', () async {
      final handler = mcpToolHandler('t', {'transport': 'http'}, connect: connect);
      await expectLater(handler({}), throwsStateError);
      expect(dialled, isEmpty);
    });
  });
}
