import 'package:appplayer_core/appplayer_core.dart';
import 'package:appplayer_core/src/bundle/bundle_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;

McpBundle _bundle({
  String? entryPoint,
  BundleType type = BundleType.application,
  bool withUi = true,
  bool withFlow = false,
  bool withSkills = false,
}) {
  return McpBundle(
    manifest: BundleManifest(
      id: 'b1',
      name: 'B',
      version: '1.0.0',
      type: type,
      entryPoint: entryPoint,
    ),
    ui: withUi ? const UiSection() : null,
    flow: withFlow ? const FlowSection() : null,
    skills: withSkills ? const SkillSection() : null,
  );
}

bool _adapt(Object? e, BundleAdaptReason reason) =>
    e is BundleAdaptException && e.reason == reason;

void main() {
  const resolver = BundleResolver();

  group('BundleResolver (MOD-BUNDLE-002)', () {
    test('TC-BUNDLE-RES-001: ui.main parsed', () {
      final entry = resolver.resolveEntry(_bundle(entryPoint: 'ui.main'));
      expect(entry.type, BundleEntryType.ui);
      expect(entry.id, 'main');
    });

    test('TC-BUNDLE-RES-002: flow.home parsed', () {
      final entry = resolver.resolveEntry(_bundle(entryPoint: 'flow.home'));
      expect(entry.type, BundleEntryType.flow);
      expect(entry.id, 'home');
    });

    test('TC-BUNDLE-RES-003: malformed entry rejected', () {
      expect(
        () => resolver.resolveEntry(_bundle(entryPoint: 'ui')),
        throwsA(predicate((e) =>
            _adapt(e, BundleAdaptReason.unsupportedEntryPoint))),
      );
      expect(
        () => resolver.resolveEntry(_bundle(entryPoint: 'ui.')),
        throwsA(predicate((e) =>
            _adapt(e, BundleAdaptReason.unsupportedEntryPoint))),
      );
      expect(
        () => resolver.resolveEntry(_bundle(entryPoint: 'bogus.main')),
        throwsA(predicate((e) =>
            _adapt(e, BundleAdaptReason.unsupportedEntryPoint))),
      );
    });

    test('TC-BUNDLE-RES-004: fallback ui only → ui.main', () {
      final entry = resolver.resolveEntry(_bundle());
      expect(entry.toString(), 'ui.main');
    });

    test('TC-BUNDLE-RES-005: fallback ambiguous → error', () {
      expect(
        () => resolver.resolveEntry(_bundle(withUi: true, withFlow: true)),
        throwsA(predicate((e) =>
            _adapt(e, BundleAdaptReason.unsupportedEntryPoint))),
      );
    });

    test('TC-BUNDLE-RES-006: type != application rejected', () {
      expect(
        () => resolver.assertApplicationType(_bundle(type: BundleType.skill)),
        throwsA(predicate((e) =>
            _adapt(e, BundleAdaptReason.invalidBundleType))),
      );
    });

    test('TC-BUNDLE-RES-007: flow entry rejected for openAppFromBundle', () {
      expect(
        () => resolver.assertUiEntry(
          const BundleEntryPoint(BundleEntryType.flow, 'home'),
          bundleId: 'b1',
        ),
        throwsA(predicate((e) =>
            _adapt(e, BundleAdaptReason.unsupportedEntryPoint))),
      );
    });
  });
}
