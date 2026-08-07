import 'package:appplayer_core/internals.dart';
import 'package:appplayer_core/appplayer_core.dart' show BundleUriResolutionException;
import 'package:flutter_test/flutter_test.dart';

/// An installed bundle's assets are FILES, and `bundle://` has to reach them.
///
/// Found live: a bundled sound reported "could not read
/// bundle://assets/beep.mp3" while the same bundle's images looked fine. The
/// resolver was built with the assets *section* only and no bundle root, so a
/// URI naming a file on disk matched nothing and was handed to the runtime
/// unrewritten. Images hid it by falling back quietly; audio could not.
void main() {
  test('bundle:// resolves to the file inside the installed directory', () {
    final resolver = BundleUriResolver(bundleRootPath: '/apps/demo');
    expect(
      resolver.resolve('bundle://assets/beep.mp3').target.toString(),
      'file:///apps/demo/assets/beep.mp3',
    );
  });

  test('without a root there is nothing to resolve against', () {
    final resolver = BundleUriResolver();
    expect(
      () => resolver.resolve('bundle://assets/beep.mp3'),
      throwsA(isA<BundleUriResolutionException>()),
      reason: 'the failure must be visible, not a URI passed through as if it '
          'had been resolved',
    );
  });

  test('rewriting a definition reaches every bundle:// string in it', () {
    final resolver = BundleUriResolver(bundleRootPath: '/apps/demo');
    final rewritten = resolver.rewriteDefinition(<String, dynamic>{
      'type': 'linear',
      'children': [
        {'type': 'image', 'src': 'bundle://assets/logo.png'},
        {
          'type': 'button',
          'click': {'type': 'sound.play', 'source': 'bundle://assets/beep.mp3'},
        },
      ],
    }) as Map<String, dynamic>;

    final children = rewritten['children'] as List<dynamic>;
    expect((children[0] as Map)['src'], 'file:///apps/demo/assets/logo.png');
    expect(
      ((children[1] as Map)['click'] as Map)['source'],
      'file:///apps/demo/assets/beep.mp3',
      reason: 'an action source is as much a bundle asset as an image slot — '
          'a rewrite that covers one and not the other is the drift that made '
          'the picture appear and the beep stay silent',
    );
  });
}
