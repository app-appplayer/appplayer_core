/// Credentials for served addresses whose calls need a person: asked before
/// each request, and after a 401 asked whether to try once more.
library;

import 'dart:async';

import 'package:appplayer_core/src/connection/connection_manager.dart';
import 'package:appplayer_core/src/connection/connection_result.dart';
import 'package:appplayer_core/src/connection/serving_authorization.dart';
import 'package:appplayer_core/src/connection/shared_client.dart';
import 'package:appplayer_core/src/model/server_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;

/// A server that refuses `tools/call` for want of a person [refusals] times,
/// the way `mcp_client` reports an HTTP 401 (`-32001`), then answers.
class _Server implements ClientTransport {
  _Server({this.refusals = 0});

  int refusals;
  int calls = 0;
  final _in = StreamController<dynamic>.broadcast();
  final _closed = Completer<void>();

  @override
  Stream<dynamic> get onMessage => _in.stream;
  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(dynamic message) {
    final m = Map<String, dynamic>.from(message as Map);
    final id = m['id'];
    if (id == null) return;
    if (m['method'] == 'tools/call') {
      calls++;
      if (refusals > 0) {
        refusals--;
        scheduleMicrotask(() => _in.add({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32001, 'message': 'Authentication required'},
            }));
        return;
      }
    }
    final Map<String, dynamic> result = switch (m['method']) {
      'initialize' => {
          'protocolVersion': '2025-03-26',
          'serverInfo': {'name': 'svc', 'version': '1'},
          'capabilities': {'tools': {}},
        },
      'tools/call' => {
          'content': [
            {'type': 'text', 'text': 'ok'}
          ]
        },
      _ => <String, dynamic>{},
    };
    scheduleMicrotask(
        () => _in.add({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

Future<(SharedClient, _Server)> _shared(
  int refusals,
  UnauthorizedHandler? onUnauthorized,
) async {
  final server = _Server(refusals: refusals);
  final inner = Client(name: 't', version: '1');
  await inner.connect(server);
  return (
    SharedClient(inner, const ConnectionSharing(),
        onUnauthorized: onUnauthorized),
    server,
  );
}

class _Auth implements ServingAuthorization {
  _Auth({this.header, this.retry});

  String? header;
  final String? retry;
  final asked = <Uri>[];
  final refused = <(Uri, String?)>[];

  @override
  Future<String?> authorizationFor(Uri endpoint) async {
    asked.add(endpoint);
    return header;
  }

  @override
  Future<String?> afterUnauthorized(Uri endpoint,
      {String? wwwAuthenticate}) async {
    refused.add((endpoint, wwwAuthenticate));
    return retry;
  }
}

class _Visitor implements ServingHeaders {
  @override
  Future<Map<String, String>> headersFor(Uri endpoint) async =>
      {'x-safepage-visitor': 'v-1'};
}

ServerConfig _served() => ServerConfig(
      id: 'svc',
      name: 'Owner contact',
      description: '',
      transportType: TransportType.streamableHttp,
      transportConfig: const {
        'baseUrl': 'https://api.safepage.test/api/mcp/s/T.owner-contact/C-1',
      },
    );

void main() {
  group('a refusal for want of a person', () {
    test('is retried once after the host signs someone in', () async {
      var asked = 0;
      final (c, s) = await _shared(1, () async {
        asked++;
        return true;
      });
      final result = await c.callTool('holder.inbox', const {});
      expect(asked, 1);
      expect(s.calls, 2);
      expect((result.content.single as TextContent).text, 'ok');
    });

    test('stands when the host signs nobody in', () async {
      final (c, s) = await _shared(1, () async => false);
      await expectLater(
          c.callTool('holder.inbox', const {}), throwsA(isA<McpError>()));
      expect(s.calls, 1);
    });

    test('is never retried twice', () async {
      var asked = 0;
      final (c, s) = await _shared(5, () async {
        asked++;
        return true;
      });
      await expectLater(
          c.callTool('holder.inbox', const {}), throwsA(isA<McpError>()));
      expect(asked, 1, reason: 'a second refusal is the answer');
      expect(s.calls, 2);
    });

    test('stands as it came without a host handler', () async {
      final (c, s) = await _shared(1, null);
      await expectLater(
          c.callTool('holder.inbox', const {}), throwsA(isA<McpError>()));
      expect(s.calls, 1);
    });
  });

  group('the 401 challenge', () {
    test('is remembered once, and only for a 401', () async {
      final recorder = ChallengeRecordingClient(MockClient((request) async {
        if (request.url.path == '/refuse') {
          return http.Response('', 401, headers: {
            'www-authenticate':
                'Bearer realm="safepage", error="invalid_token"',
          });
        }
        return http.Response('{}', 200);
      }));
      await recorder.get(Uri.parse('https://x.test/ok'));
      expect(recorder.takeChallenge(), isNull);
      await recorder.get(Uri.parse('https://x.test/refuse'));
      expect(recorder.takeChallenge(), contains('realm="safepage"'));
      expect(recorder.takeChallenge(), isNull, reason: 'answered once');
    });
  });

  group('a connection with a host answering credentials', () {
    test('a served address asks the host before each request', () async {
      final auth = _Auth(header: 'Bearer t1');
      RequestHeadersProvider? provider;
      http.Client? httpClient;
      final m = ConnectionManager(
        connector: (_) async => fail('the plain connector was used'),
        authorizedConnector: (transport, headers, client) async {
          provider = headers;
          httpClient = client;
          final inner = Client(name: 't', version: '1');
          await inner.connect(_Server());
          return inner;
        },
      )..servingAuthorization = auth;

      final result = await m.connect(_served());
      expect(result, isA<ConnectionSuccess>());
      expect(httpClient, isA<ChallengeRecordingClient>());

      const url = 'https://api.safepage.test/api/mcp/s/T.owner-contact/C-1';
      expect(await provider!((url: url, method: 'tools/call')),
          {'Authorization': 'Bearer t1'});
      auth.header = null;
      expect(await provider!((url: url, method: 'tools/call')), isEmpty,
          reason: 'nobody signed in sends nothing');
      expect(auth.asked.last, Uri.parse(url));
    });

    test('after a refusal the host is asked with the served address', () async {
      final auth = _Auth(retry: 'Bearer t2');
      final m = ConnectionManager(
        authorizedConnector: (transport, headers, client) async {
          final inner = Client(name: 't', version: '1');
          await inner.connect(_Server(refusals: 1));
          return inner;
        },
      )..servingAuthorization = auth;
      final result = await m.connect(_served()) as ConnectionSuccess;
      final client = result.connection!.client! as SharedClient;

      final answer = await client.callTool('holder.inbox', const {});
      expect((answer.content.single as TextContent).text, 'ok');
      expect(auth.refused.single.$1,
          Uri.parse('https://api.safepage.test/api/mcp/s/T.owner-contact/C-1'));
    });

    test(
        'a device on board wire is dialled by the host connector (FR-CONN-012)',
        () async {
      for (final address in [
        'tcp://10.0.2.2:9111',
        'ble://AA:BB:CC:DD:EE:FF',
        'serial:///dev/ttyUSB0',
      ]) {
        var plain = 0;
        final m = ConnectionManager(
          connector: (_) async {
            plain++;
            final inner = Client(name: 't', version: '1');
            await inner.connect(_Server());
            return inner;
          },
          authorizedConnector: (_, __, ___) async =>
              fail('a device is not an HTTP address: $address'),
        )..servingAuthorization = _Auth(header: 'Bearer t1');
        final result = await m.connect(ServerConfig(
          id: 'device',
          name: 'device',
          description: '',
          transportType: TransportType.streamableHttp,
          transportConfig: {'baseUrl': address},
        ));
        expect(result, isA<ConnectionSuccess>(), reason: address);
        expect(plain, 1, reason: address);
      }
    });

    test(
        'other headers go on every request — with nobody signed in, and '
        'beside the credential when someone is', () async {
      RequestHeadersProvider? provider;
      final m = ConnectionManager(
        connector: (_) async => fail('the plain connector was used'),
        authorizedConnector: (transport, headers, client) async {
          provider = headers;
          final inner = Client(name: 't', version: '1');
          await inner.connect(_Server());
          return inner;
        },
      )..servingHeaders = _Visitor();

      expect(await m.connect(_served()), isA<ConnectionSuccess>());
      const url = 'https://api.safepage.test/api/mcp/s/T.owner-contact/C-1';
      expect(await provider!((url: url, method: 'tools/call')),
          {'x-safepage-visitor': 'v-1'},
          reason: 'a guest is told apart from others on the same network');

      final both = ConnectionManager(
        connector: (_) async => fail('the plain connector was used'),
        authorizedConnector: (transport, headers, client) async {
          provider = headers;
          final inner = Client(name: 't', version: '1');
          await inner.connect(_Server());
          return inner;
        },
      )
        ..servingHeaders = _Visitor()
        ..servingAuthorization = _Auth(header: 'Bearer t1');
      await both.connect(_served());
      expect(await provider!((url: url, method: 'tools/call')),
          {'x-safepage-visitor': 'v-1', 'Authorization': 'Bearer t1'});
    });

    test('without a host answer the plain connector is used', () async {
      var plain = 0;
      final m = ConnectionManager(
        connector: (_) async {
          plain++;
          final inner = Client(name: 't', version: '1');
          await inner.connect(_Server());
          return inner;
        },
        authorizedConnector: (_, __, ___) async =>
            fail('no host answer — nothing to ask'),
      );
      await m.connect(_served());
      expect(plain, 1);
    });
  });
}
