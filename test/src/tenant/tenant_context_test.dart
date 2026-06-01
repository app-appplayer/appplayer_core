import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TenantContext', () {
    test('required fields land on the instance', () {
      const ctx = TenantContext(
        appCode: 'A',
        allowedServerIds: {'s1', 's2'},
        allowedBundleIds: {'b1'},
      );
      expect(ctx.appCode, 'A');
      expect(ctx.allowedServerIds, {'s1', 's2'});
      expect(ctx.allowedBundleIds, {'b1'});
      expect(ctx.branding, isEmpty);
      expect(ctx.policies, isEmpty);
    });

    test('branding + policies are optional', () {
      const ctx = TenantContext(
        appCode: 'A',
        allowedServerIds: {},
        allowedBundleIds: {},
        branding: {'color': 'red'},
        policies: {'mfa': true},
      );
      expect(ctx.branding['color'], 'red');
      expect(ctx.policies['mfa'], isTrue);
    });
  });
}
