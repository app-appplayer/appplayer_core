import 'package:appplayer_core/src/bundle/bundle_uri_resolver.dart';
import 'package:appplayer_core/src/exceptions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;

void main() {
  group('BundleUriResolver (MOD-BUNDLE-003)', () {
    test('TC-BUNDLE-URI-001: file:// from bundle root when no asset map', () {
      final resolver = BundleUriResolver(bundleRootPath: '/tmp/bundle');
      final out = resolver.resolve('bundle://assets/icon.png');
      expect(out.target.scheme, 'file');
      expect(out.target.path, '/tmp/bundle/assets/icon.png');
      expect(out.mediaType, 'image/png');
    });

    test('TC-BUNDLE-URI-002: inline base64 asset → data URI', () {
      final assets = AssetSection(assets: [
        Asset(
          path: 'assets/icon.png',
          type: AssetType.image,
          mimeType: 'image/png',
          encoding: 'base64',
          content: 'AAA=',
        ),
      ]);
      final resolver = BundleUriResolver(assets: assets);
      final out = resolver.resolve('bundle://assets/icon.png');
      expect(out.target.scheme, 'data');
      expect(out.target.toString(), startsWith('data:image/png;base64,'));
    });

    test('TC-BUNDLE-URI-003: malformed scheme rejected', () {
      final resolver = BundleUriResolver(bundleRootPath: '/tmp');
      expect(
        () => resolver.resolve('https://x'),
        throwsA(isA<BundleUriResolutionException>()),
      );
    });

    test('TC-BUNDLE-URI-004: no mapping & no root → throws', () {
      final resolver = BundleUriResolver();
      expect(
        () => resolver.resolve('bundle://assets/icon.png'),
        throwsA(isA<BundleUriResolutionException>()),
      );
    });

    test('TC-BUNDLE-URI-005: rewriteDefinition recurses and preserves non-bundle',
        () {
      final resolver = BundleUriResolver(bundleRootPath: '/b');
      final out = resolver.rewriteDefinition({
        'icon': 'bundle://assets/icon.png',
        'url': 'https://example.com',
        'nested': [
          'bundle://images/x.jpg',
          {'k': 'bundle://data/a.json', 'plain': 'hello'},
        ],
      }) as Map<String, dynamic>;

      expect(out['icon'], 'file:///b/assets/icon.png');
      expect(out['url'], 'https://example.com');
      final nested = out['nested'] as List;
      expect(nested[0], 'file:///b/images/x.jpg');
      final nestedMap = nested[1] as Map;
      expect(nestedMap['k'], 'file:///b/data/a.json');
      expect(nestedMap['plain'], 'hello');
    });
  });
}
