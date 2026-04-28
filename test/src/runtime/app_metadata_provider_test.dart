import 'package:appplayer_core/src/bundle/bundle_uri_resolver.dart';
import 'package:appplayer_core/src/metadata/app_metadata.dart';
import 'package:appplayer_core/src/metadata/app_metadata_sink.dart';
import 'package:appplayer_core/src/runtime/app_metadata_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

ReadResourceResult _jsonResult(String text) => ReadResourceResult(
      contents: [
        ResourceContentInfo(
            uri: 'ui://app/info', mimeType: 'application/json', text: text),
      ],
    );

class _RecordingSink implements AppMetadataSink {
  AppMetadata? last;
  int callCount = 0;
  bool throwOnCall = false;

  @override
  Future<void> onMetadata(AppMetadata metadata) async {
    callCount++;
    last = metadata;
    if (throwOnCall) throw StateError('sink boom');
  }
}

void main() {
  group('AppMetadataProvider (MOD-RUNTIME-006)', () {
    late MockClient client;

    setUp(() {
      client = MockClient();
    });

    test('TC-META-001: online success', () async {
      when(() => client.readResource('ui://app/info')).thenAnswer(
        (_) async => _jsonResult(
          '{"name":"Foo","version":"2.1.0","category":"Tools","icon":"https://x/icon.png"}',
        ),
      );
      final sink = _RecordingSink();
      final provider = AppMetadataProvider(sink: sink);
      final metadata = await provider.fetchFromServer(client, 'srv1');
      await provider.publish(metadata);

      expect(metadata, isNotNull);
      expect(metadata!.name, 'Foo');
      expect(metadata.version, '2.1.0');
      expect(metadata.category, 'Tools');
      expect(metadata.iconUri, 'https://x/icon.png');
      expect(sink.callCount, 1);
    });

    test('TC-META-002: online miss returns null (graceful fallback)',
        () async {
      when(() => client.readResource('ui://app/info'))
          .thenThrow(StateError('not supported'));
      final provider = AppMetadataProvider();
      final metadata = await provider.fetchFromServer(client, 'srv1');
      expect(metadata, isNull);
    });

    test('TC-META-003: from bundle manifest', () async {
      final bundle = McpBundle(
        manifest: BundleManifest(
          id: 'b1',
          name: 'Demo',
          version: '1.0.0',
          type: BundleType.application,
          icon: 'bundle://assets/icon.png',
          category: AppCategory.entertainment,
        ),
      );
      final resolver = BundleUriResolver(bundleRootPath: '/b');
      final provider = AppMetadataProvider();
      final metadata = provider.fromBundle(bundle, resolver);
      expect(metadata.appId, 'b1');
      expect(metadata.sourceKind, 'localBundle');
      expect(metadata.iconUri, 'file:///b/assets/icon.png');
      expect(metadata.category, 'entertainment');
    });

    test('TC-META-004: sink exception swallowed', () async {
      when(() => client.readResource('ui://app/info'))
          .thenAnswer((_) async => _jsonResult('{"name":"X","version":"1"}'));
      final sink = _RecordingSink()..throwOnCall = true;
      final provider = AppMetadataProvider(sink: sink);
      final metadata = await provider.fetchFromServer(client, 'srv1');
      await provider.publish(metadata);
      expect(sink.callCount, 1);
    });

    test('TC-META-005: no sink → publish is no-op', () async {
      final provider = AppMetadataProvider();
      await provider.publish(const AppMetadata(
        appId: 'x',
        sourceKind: 'online',
        name: 'X',
        version: '1',
      ));
    });
  });
}
