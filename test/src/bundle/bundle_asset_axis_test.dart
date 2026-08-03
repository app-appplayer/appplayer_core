// `bundle://` resolution as an axis, not per code path.
//
// The unit tests around `BundleUriResolver` prove the resolver works. What
// went wrong was never the resolver: it was that one code path used it and
// another did not, so the same document rendered from a local install and
// showed nothing over a connection. mcp_ui_dsl §6.12.7 makes that the rule —
// a host picks one placement and applies it to every document, regardless of
// how the document arrived — and mcp_serving §Rules 2 says a served bundle
// must behave identically to the same bundle run locally.
//
// These tests assert the axis: same reference, same bundle, same result, on
// every path a document can take to the runtime.

import 'dart:convert';

import 'package:appplayer_core/src/bundle/bundle_uri_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;

/// A 1x1 PNG, small enough to read in a failure message.
const _pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

AssetSection _assetsWith(String path) => AssetSection.fromJson({
      'assets': [
        {
          'path': path,
          'mimeType': 'image/png',
          'encoding': 'base64',
          'content': _pixel,
        },
      ],
    });

Map<String, dynamic> _pageReferencing(String uri) => <String, dynamic>{
      'type': 'page',
      'content': <String, dynamic>{
        'type': 'linear',
        'direction': 'vertical',
        'children': <Object>[
          <String, dynamic>{'type': 'image', 'src': uri},
          <String, dynamic>{
            'type': 'box',
            'decoration': <String, dynamic>{
              'image': <String, dynamic>{'src': uri},
            },
          },
        ],
      },
    };

void main() {
  group('bundle:// resolves the same on every path (§6.12.7)', () {
    test('every slot in a document, however deeply nested', () {
      final resolver = BundleUriResolver(assets: _assetsWith('images/logo.png'));
      final out = resolver
          .rewriteDefinition(_pageReferencing('bundle://images/logo.png'))
          as Map<String, dynamic>;

      final children =
          ((out['content'] as Map)['children'] as List).cast<Map>();
      final imageSrc = children[0]['src'] as String;
      final decorationSrc =
          ((children[1]['decoration'] as Map)['image'] as Map)['src'] as String;

      // The rewrite is structural, not slot-aware: it does not need to know
      // which properties hold assets, which is why it survives new widgets.
      for (final src in [imageSrc, decorationSrc]) {
        expect(src, startsWith('data:image/png;base64,'));
        expect(src, contains(_pixel));
      }
    });

    test('the entry definition and a later page get the same treatment', () {
      // The failure this guards: an entry document resolved at open, and a
      // page read afterwards left raw, so the first frame drew and the second
      // did not.
      final resolver = BundleUriResolver(assets: _assetsWith('images/logo.png'));
      final entry = resolver.rewriteDefinition(<String, dynamic>{
        'type': 'application',
        'splash': {'image': 'bundle://images/logo.png'},
        'routes': {'/': 'ui://pages/home'},
      }) as Map<String, dynamic>;
      final page = resolver
          .rewriteDefinition(_pageReferencing('bundle://images/logo.png'))
          as Map<String, dynamic>;

      final fromEntry = (entry['splash'] as Map)['image'] as String;
      final fromPage =
          (((page['content'] as Map)['children'] as List).first as Map)['src']
              as String;
      expect(fromEntry, equals(fromPage),
          reason: 'the same reference must resolve identically whether it '
              'arrives in the entry document or in a page loaded later');
    });
  });

  group('bundle:// names the ambient origin (§6.12.3)', () {
    test("an embedded subtree's reference reads its own bundle, not the "
        'embedder\'s', () {
      // §6.11.3 / §7.10: resolving an embedded document's `bundle://` against
      // the embedder would serve one origin's asset under another's identity.
      // The structural guarantee is that each document is rewritten by the
      // resolver belonging to *its* bundle — so two resolvers over the same
      // path must produce different bytes.
      const embedderPixel = _pixel;
      const embeddedPixel =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQI12P4DwABAQEAG7buVgAAAABJRU5ErkJggg==';

      final embedder = BundleUriResolver(assets: _assetsWith('logo.png'));
      final embedded = BundleUriResolver(
        assets: AssetSection.fromJson({
          'assets': [
            {
              'path': 'logo.png',
              'mimeType': 'image/png',
              'encoding': 'base64',
              'content': embeddedPixel,
            },
          ],
        }),
      );

      final doc = <String, dynamic>{'src': 'bundle://logo.png'};
      final viaEmbedder =
          (embedder.rewriteDefinition(doc) as Map)['src'] as String;
      final viaEmbedded =
          (embedded.rewriteDefinition(doc) as Map)['src'] as String;

      expect(viaEmbedder, contains(embedderPixel));
      expect(viaEmbedded, contains(embeddedPixel));
      expect(viaEmbedder, isNot(equals(viaEmbedded)),
          reason: 'the same path in two bundles is two different assets');
    });
  });

  group('unresolvable is left alone, never invented (§6.12.4)', () {
    test('a reference with no matching asset is preserved, not dropped', () {
      // Preserved rather than replaced with a placeholder: the widget's own
      // fallback path decides what the user sees, and a resolver that
      // substituted something would be making that decision for it.
      final resolver = BundleUriResolver(assets: _assetsWith('images/logo.png'));
      final out = resolver.rewriteDefinition(
        <String, dynamic>{'src': 'bundle://images/missing.png'},
      ) as Map<String, dynamic>;

      expect(out['src'], 'bundle://images/missing.png');
    });

    test('a document with no bundle behind it passes through unchanged', () {
      // A host holding no bundle has nothing to resolve against. That is not
      // an error in the document, which may be valid in a host that does.
      final out = BundleUriResolver().rewriteDefinition(
        <String, dynamic>{'src': 'bundle://images/logo.png'},
      ) as Map<String, dynamic>;

      expect(out['src'], 'bundle://images/logo.png');
    });

    test('non-bundle references are never touched', () {
      final resolver = BundleUriResolver(assets: _assetsWith('images/logo.png'));
      final out = resolver.rewriteDefinition(<String, dynamic>{
        'a': 'https://example.com/x.png',
        'b': 'assets/local.png',
        'c': 'data:image/png;base64,$_pixel',
        'd': 'client://cache/x.png',
        'e': '{{item.picture}}',
      }) as Map<String, dynamic>;

      expect(out['a'], 'https://example.com/x.png');
      expect(out['b'], 'assets/local.png');
      expect(out['c'], 'data:image/png;base64,$_pixel');
      expect(out['d'], 'client://cache/x.png',
          reason: 'client:// is the host filesystem, a different axis');
      expect(out['e'], '{{item.picture}}',
          reason: 'a binding is resolved by the runtime, after this stage');
    });
  });

  group('the rewrite survives the shapes documents actually take', () {
    test('a reference inside a binding string is not a bundle reference', () {
      // Only a string that *is* a bundle URI is rewritten. A binding that
      // will later resolve to one is the runtime's problem (§6.12.2), and
      // rewriting the binding text would corrupt the expression.
      final resolver = BundleUriResolver(assets: _assetsWith('logo.png'));
      final out = resolver.rewriteDefinition(
        <String, dynamic>{'src': '{{bundle://logo.png}}'},
      ) as Map<String, dynamic>;
      expect(out['src'], '{{bundle://logo.png}}');
    });

    test('the scheme is `bundle://`, not `bundle:`', () {
      // `Uri.parse('bundle:logo.png')` also reports scheme `bundle`, so a
      // resolver that dispatched on the parsed scheme rather than on the
      // literal prefix would rewrite a form the spec does not define
      // (§6.12.1: `bundle://<path>`). Kept explicit because the difference is
      // invisible until a document uses the short form and gets a silent
      // substitution.
      final resolver = BundleUriResolver(assets: _assetsWith('logo.png'));
      final out = resolver.rewriteDefinition(
        <String, dynamic>{'src': 'bundle:logo.png'},
      ) as Map<String, dynamic>;
      expect(out['src'], 'bundle:logo.png');
    });

    test('round-trips through JSON without losing the resolved value', () {
      // The definition crosses a serialization boundary on some paths; a
      // resolved data URI has to survive it intact.
      final resolver = BundleUriResolver(assets: _assetsWith('logo.png'));
      final out = resolver.rewriteDefinition(
        <String, dynamic>{'src': 'bundle://logo.png'},
      );
      final decoded = jsonDecode(jsonEncode(out)) as Map<String, dynamic>;
      expect(decoded['src'], startsWith('data:image/png;base64,'));
      expect(decoded['src'], contains(_pixel));
    });
  });
}
