import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, String> files;
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(files[key]!.codeUnits));
  @override
  Future<String> loadString(String key, {bool cache = true}) async => files[key]!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(OpenSourceLicenses.resetForTest);

  test('reads the bundled list into notices', () {
    final entries = OpenSourceLicenses.parseBundled(
        '[{"packages":["quinn","quinn-proto"],"license":"MIT License\\n\\ntext"}]');
    expect(entries.single.packages, ['quinn', 'quinn-proto']);
    expect(entries.single.paragraphs.map((p) => p.text).join(), contains('MIT License'));
  });

  // A notice missing from a shipped app is the failure this exists to
  // prevent, so a bad list is loud rather than skipped (FR-LIC-004).
  for (final (why, raw) in [
    ('not a list', '{"packages":["a"],"license":"x"}'),
    ('no packages', '[{"packages":[],"license":"x"}]'),
    ('empty text', '[{"packages":["a"],"license":"  "}]'),
    ('a blank name', '[{"packages":[""],"license":"x"}]'),
  ]) {
    test('a malformed list throws: $why', () {
      expect(() => OpenSourceLicenses.parseBundled(raw), throwsFormatException);
    });
  }

  test('what the app registers shows next to what Flutter collected', () async {
    OpenSourceLicenses.registerBundled('licenses/native.json',
        bundle: _Bundle({
          'licenses/native.json':
              '[{"packages":["zz-native-only"],"license":"ISC License text"}]',
        }));
    OpenSourceLicenses.registerBundled('licenses/native.json',
        bundle: _Bundle({'licenses/native.json': '[]'}));
    final seen = <String>[];
    await for (final e in LicenseRegistry.licenses) {
      seen.addAll(e.packages);
    }
    expect(seen.where((p) => p == 'zz-native-only'), hasLength(1),
        reason: 'registered once, even when asked twice');
  });
}
