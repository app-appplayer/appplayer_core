import 'package:appplayer_core/src/dashboard/dashboard_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SlotBindingRule.fromJson', () {
    test('explicit binding', () {
      final rule = SlotBindingRule.fromJson({
        'type': 'explicit',
        'deviceId': 'd1',
      });
      expect(rule, isA<ExplicitBinding>());
      expect((rule as ExplicitBinding).deviceId, 'd1');
    });

    test('byTag binding', () {
      final rule =
          SlotBindingRule.fromJson({'type': 'byTag', 'tag': 'kitchen'});
      expect(rule, isA<TagBinding>());
      expect((rule as TagBinding).tag, 'kitchen');
    });

    test('byFilter binding', () {
      final rule = SlotBindingRule.fromJson({
        'type': 'byFilter',
        'filter': {'kind': 'light'},
      });
      expect(rule, isA<FilterBinding>());
      expect((rule as FilterBinding).filter, {'kind': 'light'});
    });

    test('unknown type throws ArgumentError', () {
      expect(
        () => SlotBindingRule.fromJson({'type': 'nope'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('explicit factory constructor', () {
      const rule = SlotBindingRule.explicit('x');
      expect(rule, isA<ExplicitBinding>());
    });

    test('byTag factory constructor', () {
      const rule = SlotBindingRule.byTag('x');
      expect(rule, isA<TagBinding>());
    });

    test('byFilter factory constructor', () {
      const rule = SlotBindingRule.byFilter({'k': 'v'});
      expect(rule, isA<FilterBinding>());
    });
  });

  group('SlotDefinition.fromJson', () {
    test('minimal slot', () {
      final s = SlotDefinition.fromJson({
        'slotId': 's1',
        'binding': {'type': 'explicit', 'deviceId': 'd1'},
      });
      expect(s.slotId, 's1');
      expect(s.binding, isA<ExplicitBinding>());
      expect(s.summaryUri, isNull);
      expect(s.filter, isNull);
    });

    test('slot with summaryUri + filter', () {
      final s = SlotDefinition.fromJson({
        'slotId': 's2',
        'binding': {'type': 'byTag', 'tag': 't'},
        'summaryUri': 'uri://sum',
        'filter': {'k': 'v'},
      });
      expect(s.summaryUri, 'uri://sum');
      expect(s.filter, {'k': 'v'});
    });
  });

  group('DashboardBundleRef', () {
    test('marketUrl source', () {
      const ref = DashboardBundleRef(
        bundleId: 'b1',
        source: BundleSource.marketUrl,
        url: 'http://example/b',
      );
      expect(ref.bundleId, 'b1');
      expect(ref.source, BundleSource.marketUrl);
      expect(ref.url, 'http://example/b');
    });

    test('inline source carries inlineDefinition', () {
      const ref = DashboardBundleRef(
        bundleId: 'b2',
        source: BundleSource.inline,
        inlineDefinition: {'k': 'v'},
      );
      expect(ref.source, BundleSource.inline);
      expect(ref.inlineDefinition, {'k': 'v'});
    });
  });

  group('DashboardBundle + SlotBinding', () {
    test('bundle wires everything', () {
      const bundle = DashboardBundle(
        id: 'd1',
        mainLayout: {'kind': 'col'},
        slots: [],
        commonActions: [
          {'id': 'reload'},
        ],
      );
      expect(bundle.id, 'd1');
      expect(bundle.commonActions.first['id'], 'reload');
    });

    test('SlotBinding stores ids', () {
      const b = SlotBinding(slotId: 's', deviceId: 'd');
      expect(b.slotId, 's');
      expect(b.deviceId, 'd');
    });
  });
}
