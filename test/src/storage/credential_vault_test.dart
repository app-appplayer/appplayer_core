import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NoopCredentialVault', () {
    const vault = NoopCredentialVault();

    test('read returns null for any key', () async {
      expect(await vault.read('any'), isNull);
      expect(await vault.read(''), isNull);
    });

    test('write is a no-op (read still returns null)', () async {
      await vault.write('k', 'v');
      expect(await vault.read('k'), isNull);
    });

    test('delete is a no-op', () async {
      await vault.delete('k');
      expect(await vault.read('k'), isNull);
    });
  });
}
