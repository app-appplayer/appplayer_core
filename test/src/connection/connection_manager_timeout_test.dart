import 'dart:async';

import 'package:appplayer_core/src/connection/connection_manager.dart';
import 'package:appplayer_core/src/model/server_config.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' hide ConnectionState;
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

ServerConfig _server() => ServerConfig(
      id: 's1',
      name: 'n',
      description: 'd',
      transportType: TransportType.stdio,
      transportConfig: const {'command': 'dart'},
    );

void main() {
  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
  });

  test('TC-CONN-005: wait timeout returns failure (FakeAsync)', () {
    fakeAsync((async) {
      final m = ConnectionManager(
        // Connector future never completes in the fake clock.
        connector: (_) => Completer<Client>().future,
        waitMaxDuration: const Duration(seconds: 30),
        waitCheckInterval: const Duration(milliseconds: 100),
      );

      // First connect — stays in `connecting`.
      m.connect(_server()).ignore();
      async.flushMicrotasks();

      // Second connect — enters the wait loop.
      String? resultError;
      m.connect(_server()).then((r) => resultError = r.error);

      // Advance just past the wait window.
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();

      expect(resultError, 'Connection timeout');
    });
  });
}
