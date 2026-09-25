import 'dart:async';

import 'package:appplayer_core/src/connection/shared_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;

/// A server stand-in that answers per method and can hold answers back, so a
/// test sees exactly what reached the device.
class _Server implements ClientTransport {
  _Server({this.listChanged = false});

  final bool listChanged;
  final _in = StreamController<dynamic>.broadcast();
  final _closed = Completer<void>();
  final sent = <Map<String, dynamic>>[];
  bool hold = false;
  final held = <Map<String, dynamic>>[];

  int count(String method) => sent.where((m) => m['method'] == method).length;
  int reads(String uri) => sent
      .where((m) => m['method'] == 'resources/read' && m['params']['uri'] == uri)
      .length;
  void push(Map<String, dynamic> n) => _in.add(n);
  void releaseOne() {
    if (held.isNotEmpty) _in.add(held.removeAt(0));
  }

  @override
  Stream<dynamic> get onMessage => _in.stream;
  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(dynamic message) {
    final m = Map<String, dynamic>.from(message as Map);
    sent.add(m);
    final id = m['id'];
    if (id == null) return;
    final Map<String, dynamic> result = switch (m['method']) {
      'initialize' => {
          'protocolVersion': '2025-03-26',
          'serverInfo': {'name': 'node', 'version': '1'},
          'capabilities': {
            'tools': {'listChanged': listChanged},
            'resources': {'subscribe': true, 'listChanged': listChanged},
            'prompts': {},
          },
        },
      'tools/list' => {'tools': <dynamic>[]},
      'resources/list' => {'resources': <dynamic>[]},
      'resources/read' => {
          'contents': [
            {'uri': m['params']['uri'], 'text': 'x'}
          ]
        },
      'tools/call' => {
          'content': [
            {'type': 'text', 'text': 'ok'}
          ]
        },
      _ => <String, dynamic>{},
    };
    final reply = {'jsonrpc': '2.0', 'id': id, 'result': result};
    if (hold && m['method'] != 'initialize') {
      held.add(reply);
    } else {
      scheduleMicrotask(() => _in.add(reply));
    }
  }

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

Future<(SharedClient, _Server)> _shared(ConnectionSharing sharing,
    {bool listChanged = false}) async {
  final server = _Server(listChanged: listChanged);
  final inner = Client(name: 't', version: '1');
  await inner.connect(server);
  return (SharedClient(inner, sharing), server);
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

const _device = ConnectionSharing(surfaceFixed: true, maxInFlight: 1);

void main() {
  group('SharedClient (spec 23 §6.1)', () {
    test('lists: seven consumers at once reach the device once', () async {
      final (c, s) = await _shared(_device);
      await Future.wait([for (var i = 0; i < 7; i++) c.listTools()]);
      await c.listTools();
      expect(s.count('tools/list'), 1);
    });

    test('lists are read again only after the server says they changed',
        () async {
      final (c, s) = await _shared(_device);
      await c.listResources();
      s.push({'jsonrpc': '2.0', 'method': 'notifications/resources/list_changed'});
      await _settle();
      await c.listResources();
      expect(s.count('resources/list'), 2);
    });

    test('documents are read once per connection; unsubscribed state is not '
        'kept', () async {
      final (c, s) = await _shared(_device);
      for (var i = 0; i < 5; i++) {
        await c.readResource('ui://app');
        await c.readResource('sensor://uptime');
      }
      expect(s.reads('ui://app'), 1);
      expect(s.reads('sensor://uptime'), 5,
          reason: 'an unsubscribed value may change silently (MCP)');
    });

    test('reads already on their way are shared', () async {
      final (c, s) = await _shared(_device);
      s.hold = true;
      final reads = [for (var i = 0; i < 4; i++) c.readResource('sensor://x')];
      await _settle();
      expect(s.reads('sensor://x'), 1);
      s.releaseOne();
      await Future.wait(reads);
    });

    test('a subscribed value is answered from the pushed one', () async {
      final (c, s) = await _shared(_device);
      await c.subscribeResource('sensor://led');
      s.push({
        'jsonrpc': '2.0',
        'method': 'notifications/resources/updated',
        'params': {
          'uri': 'sensor://led',
          'content': {'uri': 'sensor://led', 'text': '{"state":"on"}'},
        },
      });
      await _settle();
      final r = await c.readResource('sensor://led');
      expect(s.reads('sensor://led'), 0);
      expect((r.contents.first as dynamic).text, '{"state":"on"}');
    });

    test('a subscribed value read once is reused until the device announces '
        'a change', () async {
      final (c, s) = await _shared(_device);
      await c.subscribeResource('sensor://led');
      await c.readResource('sensor://led'); // no push yet: goes to the device
      await c.readResource('sensor://led');
      await c.readResource('sensor://led');
      expect(s.reads('sensor://led'), 1);
      s.push({
        'jsonrpc': '2.0',
        'method': 'notifications/resources/updated',
        'params': {'uri': 'sensor://led'},
      });
      await _settle();
      await c.readResource('sensor://led');
      expect(s.reads('sensor://led'), 2, reason: 'a URI-only update drops it');
    });

    test('the consumer still gets its notification, after the bookkeeping',
        () async {
      final (c, s) = await _shared(_device);
      await c.readResource('ui://page/main');
      String? seen;
      var readsWhenNotified = -1;
      c.onResourceUpdated((uri) {
        seen = uri;
        readsWhenNotified = s.reads('ui://page/main');
      });
      s.push({
        'jsonrpc': '2.0',
        'method': 'notifications/resources/updated',
        'params': {'uri': 'ui://page/main'},
      });
      await _settle();
      expect(seen, 'ui://page/main');
      expect(readsWhenNotified, 1);
      await c.readResource('ui://page/main');
      expect(s.reads('ui://page/main'), 2, reason: 'the kept copy was dropped');
    });

    test('calls wait here, one at a time; the probe never waits', () async {
      final (c, s) = await _shared(_device);
      s.hold = true;
      final a = c.callTool('led.set', {'on': true});
      final b = c.callTool('led.set', {'on': false});
      await _settle();
      expect(s.count('tools/call'), 1);
      unawaited(c.ping());
      await _settle();
      expect(s.count('ping'), 1);
      s.releaseOne(); // first call
      await a;
      await _settle();
      expect(s.count('tools/call'), 2);
      s.releaseOne(); // ping
      s.releaseOne(); // second call
      await b;
    });

    test('anything coming back moves lastMessageAt — a stream is life',
        () async {
      final (c, s) = await _shared(_device);
      expect(c.lastMessageAt, isNull);
      await c.listTools();
      final afterReply = c.lastMessageAt!;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      s.push({
        'jsonrpc': '2.0',
        'method': 'notifications/resources/updated',
        'params': {'uri': 'sensor://uptime'},
      });
      await _settle();
      expect(c.lastMessageAt!.isAfter(afterReply), isTrue);
    });

    test('a general server: lists kept only when it promised to announce '
        'changes; documents not kept', () async {
      final (quiet, qs) = await _shared(const ConnectionSharing());
      await quiet.listTools();
      await quiet.listTools();
      await quiet.readResource('ui://app');
      await quiet.readResource('ui://app');
      expect(qs.count('tools/list'), 2);
      expect(qs.reads('ui://app'), 2);

      final (promised, ps) =
          await _shared(const ConnectionSharing(), listChanged: true);
      await promised.listTools();
      await promised.listTools();
      expect(ps.count('tools/list'), 1);
    });
  });
}
