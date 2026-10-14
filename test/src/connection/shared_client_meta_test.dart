/// A request carrying `_meta` speaks for one caller: the shared connection
/// passes the `_meta` on, and never answers it from (or into) what consumers
/// share.
library;

import 'dart:async';

import 'package:appplayer_core/src/connection/shared_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;

/// A server that records every request it is sent.
class _Server implements ClientTransport {
  final List<Map<String, dynamic>> sent = [];
  final _in = StreamController<dynamic>.broadcast();
  final _closed = Completer<void>();

  @override
  Stream<dynamic> get onMessage => _in.stream;
  @override
  Future<void> get onClose => _closed.future;

  List<Map<String, dynamic>> of(String method) => [
        for (final m in sent)
          if (m['method'] == method) m
      ];

  @override
  void send(dynamic message) {
    final m = Map<String, dynamic>.from(message as Map);
    final id = m['id'];
    if (id == null) return;
    sent.add(m);
    final Map<String, dynamic> result = switch (m['method']) {
      'initialize' => {
          'protocolVersion': '2025-03-26',
          'serverInfo': {'name': 'svc', 'version': '1'},
          // Declaring listChanged is what lets a list be kept.
          'capabilities': {
            'tools': {'listChanged': true},
            'resources': {},
          },
        },
      'tools/list' => {
          'tools': [
            {
              'name': 'a',
              'inputSchema': {'type': 'object'}
            }
          ]
        },
      'tools/call' => {
          'content': [
            {'type': 'text', 'text': 'ok'}
          ]
        },
      'resources/read' => {
          'contents': [
            {'uri': 'x://a', 'text': 'v'}
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

Future<(SharedClient, _Server)> _shared() async {
  final server = _Server();
  final inner = Client(name: 't', version: '1');
  await inner.connect(server);
  return (SharedClient(inner, const ConnectionSharing()), server);
}

void main() {
  const access = {
    'access': {'member': 'm/u1', 'unit': 'u'}
  };

  test('callTool hands its meta to the server as params._meta', () async {
    final (client, server) = await _shared();
    await client.callTool('a', const {}, meta: access);
    expect(server.of('tools/call').single['params']['_meta'], access);
  });

  test('callTool without meta sends no _meta', () async {
    final (client, server) = await _shared();
    await client.callTool('a', const {});
    expect(
        (server.of('tools/call').single['params'] as Map).containsKey('_meta'),
        isFalse);
  });

  test('a list asked with meta is asked every time, never from the kept list',
      () async {
    final (client, server) = await _shared();
    await client.listTools();
    await client.listTools();
    expect(server.of('tools/list'), hasLength(1), reason: 'shared list kept');

    await client.listTools(meta: access);
    await client.listTools(meta: access);
    final asked = server.of('tools/list');
    expect(asked, hasLength(3));
    expect(asked[1]['params']['_meta'], access);
    expect(asked[2]['params']['_meta'], access);

    // And what the caller got did not replace the shared list.
    await client.listTools();
    expect(server.of('tools/list'), hasLength(3));
  });

  test('a read with meta goes to the server and carries the meta', () async {
    final (client, server) = await _shared();
    await client.readResource('x://a', meta: access);
    await client.readResource('x://a', meta: access);
    final reads = server.of('resources/read');
    expect(reads, hasLength(2));
    expect(reads.first['params']['_meta'], access);
  });
}
