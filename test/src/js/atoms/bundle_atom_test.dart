import 'package:appplayer_core/internals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;

mb.McpBundle _bundle({
  String id = 'com.example.app',
  String name = 'Example',
  String version = '1.2.3',
  String? directory = '/tmp/example',
}) {
  return mb.McpBundle(
    manifest: mb.BundleManifest(id: id, name: name, version: version),
    directory: directory,
  );
}

void main() {
  group('BundleAtom', () {
    test('key + verbs declared', () {
      final atom = BundleAtom(bundle: _bundle());
      expect(atom.key, 'bundle');
      expect(atom.verbs.map((v) => v.name).toList(), ['current']);
    });

    test('current returns id / name / shortId / version / directory',
        () async {
      final atom = BundleAtom(bundle: _bundle());
      final out = await atom.dispatch('current', const []) as Map;
      expect(out['id'], 'com.example.app');
      expect(out['name'], 'Example');
      expect(out['version'], '1.2.3');
      expect(out['shortId'], 'app');
      expect(out['directory'], '/tmp/example');
    });

    test('current shortId equals id when no dot is present', () async {
      final atom = BundleAtom(bundle: _bundle(id: 'standalone'));
      final out = await atom.dispatch('current', const []) as Map;
      expect(out['shortId'], 'standalone');
    });

    test('current returns null directory when bundle has none', () async {
      final atom = BundleAtom(bundle: _bundle(directory: null));
      final out = await atom.dispatch('current', const []) as Map;
      expect(out['directory'], isNull);
    });

    test('unknown verb throws ArgumentError', () async {
      final atom = BundleAtom(bundle: _bundle());
      expect(
        () => atom.dispatch('nope', const []),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
