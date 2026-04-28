import 'package:appplayer_core/src/connection/transport_factory.dart';
import 'package:appplayer_core/src/model/server_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';

ServerConfig _cfg({
  required TransportType type,
  required Map<String, dynamic> config,
}) =>
    ServerConfig(
      id: 'id',
      name: 'n',
      description: 'd',
      transportType: type,
      transportConfig: config,
    );

void main() {
  const factory = TransportFactory();

  group('TransportFactory (MOD-CONN-002)', () {
    test('TC-TRANS-001: stdio', () {
      final result = factory.create(_cfg(
        type: TransportType.stdio,
        config: const {
          'command': 'dart',
          'arguments': ['run', 'bin/server.dart'],
          'workingDirectory': '/tmp',
        },
      ));
      expect(result, isA<StdioTransportConfig>());
      final s = result as StdioTransportConfig;
      expect(s.command, 'dart');
      expect(s.arguments, ['run', 'bin/server.dart']);
      expect(s.workingDirectory, '/tmp');
    });

    test('TC-TRANS-002: sse full config', () {
      final result = factory.create(_cfg(
        type: TransportType.sse,
        config: const {
          'serverUrl': 'https://x',
          'bearerToken': 'tok',
          'enableCompression': true,
          'heartbeatInterval': 30,
        },
      ));
      expect(result, isA<SseTransportConfig>());
      final s = result as SseTransportConfig;
      expect(s.serverUrl, 'https://x');
      expect(s.bearerToken, 'tok');
      expect(s.enableCompression, true);
      expect(s.heartbeatInterval, const Duration(seconds: 30));
    });

    test('TC-TRANS-003: sse heartbeat null', () {
      final result = factory.create(_cfg(
        type: TransportType.sse,
        config: const {'serverUrl': 'https://x'},
      ));
      final s = result as SseTransportConfig;
      expect(s.heartbeatInterval, isNull);
      expect(s.enableCompression, isFalse);
    });

    test('TC-TRANS-004: streamableHttp', () {
      final result = factory.create(_cfg(
        type: TransportType.streamableHttp,
        config: const {
          'baseUrl': 'https://api',
          'useHttp2': false,
          'timeout': 10,
        },
      ));
      expect(result, isA<StreamableHttpTransportConfig>());
      final s = result as StreamableHttpTransportConfig;
      expect(s.baseUrl, 'https://api');
      expect(s.useHttp2, false);
      expect(s.timeout, const Duration(seconds: 10));
      expect(s.terminateOnClose, false);
    });

    test('TC-TRANS-005: missing required field throws ArgumentError', () {
      expect(
        () => factory.create(_cfg(
          type: TransportType.stdio,
          config: const {},
        )),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => factory.create(_cfg(
          type: TransportType.sse,
          config: const {},
        )),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => factory.create(_cfg(
          type: TransportType.streamableHttp,
          config: const {},
        )),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
