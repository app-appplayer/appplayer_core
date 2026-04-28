import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;

import '../exceptions.dart';
import 'bundle_entry_point.dart';

/// Parses `BundleManifest.entryPoint` and validates type/entry compatibility
/// (MOD-BUNDLE-002, FR-BUNDLE-002 / FR-APP-LOCAL-002~003).
class BundleResolver {
  const BundleResolver();

  /// FR-BUNDLE-002
  BundleEntryPoint resolveEntry(McpBundle bundle) {
    final bundleId = bundle.manifest.id;
    final raw = bundle.manifest.entryPoint ?? _default(bundle);
    final parts = raw.split('.');
    if (parts.length != 2) {
      throw BundleAdaptException(
        bundleId: bundleId,
        reason: BundleAdaptReason.unsupportedEntryPoint,
        message: 'Entry point must be "<type>.<id>" — got "$raw"',
      );
    }

    final BundleEntryType type;
    switch (parts[0]) {
      case 'ui':
        type = BundleEntryType.ui;
        break;
      case 'flow':
        type = BundleEntryType.flow;
        break;
      case 'skill':
        type = BundleEntryType.skill;
        break;
      default:
        throw BundleAdaptException(
          bundleId: bundleId,
          reason: BundleAdaptReason.unsupportedEntryPoint,
          message: 'Unknown entry type: "${parts[0]}"',
        );
    }

    final id = parts[1];
    if (id.isEmpty) {
      throw BundleAdaptException(
        bundleId: bundleId,
        reason: BundleAdaptReason.unsupportedEntryPoint,
        message: 'Entry id is empty in "$raw"',
      );
    }

    return BundleEntryPoint(type, id);
  }

  /// FR-APP-LOCAL-002
  void assertApplicationType(McpBundle bundle) {
    if (bundle.manifest.type != BundleType.application) {
      throw BundleAdaptException(
        bundleId: bundle.manifest.id,
        reason: BundleAdaptReason.invalidBundleType,
        message:
            'Expected ${BundleType.application.name}, got ${bundle.manifest.type.name}',
      );
    }
  }

  /// FR-APP-LOCAL-003
  void assertUiEntry(BundleEntryPoint entry, {required String bundleId}) {
    if (entry.type != BundleEntryType.ui) {
      throw BundleAdaptException(
        bundleId: bundleId,
        reason: BundleAdaptReason.unsupportedEntryPoint,
        message:
            'AppPlayer openAppFromBundle supports ui.* entries only — got $entry',
      );
    }
  }

  String _default(McpBundle bundle) {
    final hasUi = bundle.ui != null;
    final hasFlow = bundle.flow != null;
    final hasSkill = bundle.skills != null;

    final present = [hasUi, hasFlow, hasSkill].where((x) => x).length;
    if (present != 1) {
      throw BundleAdaptException(
        bundleId: bundle.manifest.id,
        reason: BundleAdaptReason.unsupportedEntryPoint,
        message:
            'Ambiguous or missing entry point — set manifest.entryPoint explicitly (ui:$hasUi flow:$hasFlow skill:$hasSkill)',
      );
    }
    if (hasUi) return 'ui.main';
    if (hasFlow) return 'flow.main';
    return 'skill.main';
  }
}
