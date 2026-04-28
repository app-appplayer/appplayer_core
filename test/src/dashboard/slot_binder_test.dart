import 'package:appplayer_core/src/dashboard/dashboard_bundle.dart';
import 'package:appplayer_core/src/dashboard/slot_binder.dart';
import 'package:appplayer_core/src/exceptions.dart';
import 'package:flutter_test/flutter_test.dart';

SlotDefinition _slot(String id, SlotBindingRule binding) =>
    SlotDefinition(slotId: id, binding: binding);

void main() {
  final binder = SlotBinder();

  group('SlotBinder (MOD-DASH-003)', () {
    test('TC-SLOT-001: explicit binding matches existing device', () {
      final r = binder.bind(
        slots: [_slot('s', const SlotBindingRule.explicit('d1'))],
        deviceIds: const ['d1', 'd2'],
      );
      expect(r.single.deviceId, 'd1');
    });

    test('TC-SLOT-002: explicit unknown → throws', () {
      expect(
        () => binder.bind(
          slots: [_slot('s', const SlotBindingRule.explicit('d99'))],
          deviceIds: const ['d1'],
        ),
        throwsA(isA<SlotBindingException>()),
      );
    });

    test('TC-SLOT-003: byTag picks tagged device', () {
      final r = binder.bind(
        slots: [_slot('s', const SlotBindingRule.byTag('line-a'))],
        deviceIds: const ['d1', 'd2'],
        deviceMetadata: const {
          'd1': {
            'tags': ['line-a'],
          },
          'd2': {
            'tags': ['line-b'],
          },
        },
      );
      expect(r.single.deviceId, 'd1');
    });

    test('TC-SLOT-004: byTag no match → throws', () {
      expect(
        () => binder.bind(
          slots: [_slot('s', const SlotBindingRule.byTag('line-a'))],
          deviceIds: const ['d1'],
          deviceMetadata: const {
            'd1': {'tags': <String>[]},
          },
        ),
        throwsA(isA<SlotBindingException>()),
      );
    });

    test('TC-SLOT-005: byFilter equality match', () {
      final r = binder.bind(
        slots: [
          _slot('s',
              const SlotBindingRule.byFilter({'type': 'sensor'})),
        ],
        deviceIds: const ['d1'],
        deviceMetadata: const {
          'd1': {'type': 'sensor'},
        },
      );
      expect(r.single.deviceId, 'd1');
    });

    test('TC-SLOT-006: used devices not reassigned', () {
      final bindings = binder.bind(
        slots: [
          _slot('s1', const SlotBindingRule.byTag('sensor')),
          // second slot cannot use same device → throws
        ],
        deviceIds: const ['d1'],
        deviceMetadata: const {
          'd1': {
            'tags': ['sensor'],
          },
        },
      );
      expect(bindings.single.slotId, 's1');
      expect(
        () => binder.bind(
          slots: [
            _slot('s1', const SlotBindingRule.byTag('sensor')),
            _slot('s2', const SlotBindingRule.byTag('sensor')),
          ],
          deviceIds: const ['d1'],
          deviceMetadata: const {
            'd1': {
              'tags': ['sensor'],
            },
          },
        ),
        throwsA(isA<SlotBindingException>()),
      );
    });

    test('TC-SLOT-007: no slots → empty result', () {
      expect(binder.bind(slots: const [], deviceIds: const ['d1']), isEmpty);
    });

    test('TC-SLOT-008: no devices → throw', () {
      expect(
        () => binder.bind(
          slots: [_slot('s', const SlotBindingRule.explicit('d1'))],
          deviceIds: const [],
        ),
        throwsA(isA<SlotBindingException>()),
      );
    });
  });
}
