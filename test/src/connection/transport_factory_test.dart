import 'dart:ui' show Locale;

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

    test(
        'TC-TRANS-007: streamableHttp carries accessToken as Authorization '
        'Bearer (dropping it = unauthenticated handshake → the marketplace '
        'service-connect 401)', () {
      final result = factory.create(_cfg(
        type: TransportType.streamableHttp,
        config: const {
          'baseUrl': 'https://api/mcp',
          'accessToken': 'tok-123',
        },
      ));
      final s = result as StreamableHttpTransportConfig;
      expect(s.headers, {'Authorization': 'Bearer tok-123'});
    });

    test(
        'TC-TRANS-008: streamableHttp headers pass through and an explicit '
        'header wins over the token-derived one', () {
      final result = factory.create(_cfg(
        type: TransportType.streamableHttp,
        config: const {
          'baseUrl': 'https://api/mcp',
          'accessToken': 'tok-123',
          'headers': {'X-API-Key': 'tok-123', 'Authorization': 'Custom x'},
        },
      ));
      final s = result as StreamableHttpTransportConfig;
      expect(s.headers, {
        'Authorization': 'Custom x',
        'X-API-Key': 'tok-123',
      });

      // No token, no headers → null (unchanged behaviour).
      final bare = factory.create(_cfg(
        type: TransportType.streamableHttp,
        config: const {'baseUrl': 'https://api/mcp'},
      )) as StreamableHttpTransportConfig;
      expect(bare.headers, isNull);
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

  group('Accept-Language (FR-CONN-011)', () {
    ServerConfig http0([Map<String, dynamic> extra = const {}]) => _cfg(
          type: TransportType.streamableHttp,
          config: {'baseUrl': 'https://api.example.test/mcp', ...extra},
        );

    test('TC-TRANS-009: streamable HTTP carries the language', () {
      final result = factory.create(
        http0(const {'accessToken': 'tok'}),
        acceptLanguage: 'ko-KR, en-US;q=0.9',
      ) as StreamableHttpTransportConfig;
      expect(result.headers, {
        'Accept-Language': 'ko-KR, en-US;q=0.9',
        'Authorization': 'Bearer tok',
      });
    });

    test('TC-TRANS-010: a header the config names wins, whatever its case', () {
      final result = factory.create(
        http0(const {
          'headers': {'accept-language': 'ja-JP'},
        }),
        acceptLanguage: 'ko-KR',
      ) as StreamableHttpTransportConfig;
      expect(result.headers, {'accept-language': 'ja-JP'});
    });

    test('TC-TRANS-010: stdio and sse are unchanged by a language', () {
      final stdio = factory.create(
        _cfg(type: TransportType.stdio, config: const {'command': 'dart'}),
        acceptLanguage: 'ko-KR',
      );
      expect(stdio, isA<StdioTransportConfig>());
      final sse = factory.create(
        _cfg(
            type: TransportType.sse,
            config: const {'serverUrl': 'https://x.test/sse'}),
        acceptLanguage: 'ko-KR',
      ) as SseTransportConfig;
      expect(sse.headers, isNull);
    });

    test('TC-TRANS-011: acceptLanguageOf', () {
      expect(
        acceptLanguageOf(const [
          Locale('ko', 'KR'),
          Locale('en', 'US'),
          Locale('ja'),
        ]),
        'ko-KR, en-US;q=0.9, ja;q=0.8',
      );
      expect(acceptLanguageOf(const []), isNull);
      final many = acceptLanguageOf(List.filled(12, const Locale('en')))!;
      expect(many.split(', ').last, 'en;q=0.1');
    });
  });
}
