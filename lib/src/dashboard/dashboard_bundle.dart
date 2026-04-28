/// Sources from which a dashboard bundle can be loaded.
enum BundleSource {
  marketUrl,
  inline,
  aggregatorServer,
  synthesized,
}

/// Rule for binding a slot to a device.
sealed class SlotBindingRule {
  const SlotBindingRule();

  const factory SlotBindingRule.explicit(String deviceId) =
      ExplicitBinding;
  const factory SlotBindingRule.byTag(String tag) = TagBinding;
  const factory SlotBindingRule.byFilter(Map<String, dynamic> filter) =
      FilterBinding;

  factory SlotBindingRule.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'explicit':
        return SlotBindingRule.explicit(json['deviceId'] as String);
      case 'byTag':
        return SlotBindingRule.byTag(json['tag'] as String);
      case 'byFilter':
        return SlotBindingRule.byFilter(
          Map<String, dynamic>.from(json['filter'] as Map),
        );
      default:
        throw ArgumentError('Unknown slot binding type: $type');
    }
  }
}

final class ExplicitBinding extends SlotBindingRule {
  const ExplicitBinding(this.deviceId);
  final String deviceId;
}

final class TagBinding extends SlotBindingRule {
  const TagBinding(this.tag);
  final String tag;
}

final class FilterBinding extends SlotBindingRule {
  const FilterBinding(this.filter);
  final Map<String, dynamic> filter;
}

/// Declaration of a single dashboard slot.
class SlotDefinition {
  const SlotDefinition({
    required this.slotId,
    required this.binding,
    this.summaryUri,
    this.filter,
  });

  final String slotId;
  final SlotBindingRule binding;
  final String? summaryUri;
  final Map<String, dynamic>? filter;

  factory SlotDefinition.fromJson(Map<String, dynamic> json) {
    return SlotDefinition(
      slotId: json['slotId'] as String,
      binding: SlotBindingRule.fromJson(
        Map<String, dynamic>.from(json['binding'] as Map),
      ),
      summaryUri: json['summaryUri'] as String?,
      filter: json['filter'] == null
          ? null
          : Map<String, dynamic>.from(json['filter'] as Map),
    );
  }
}

/// Reference used to locate a dashboard bundle (MOD-MODEL-004).
///
/// Distinct from the `BundleRef` in `src/bundle/` (which points to an
/// `mcp_bundle.McpBundle` application). A `DashboardBundleRef` references
/// the dashboard-only schema that Dashboard Mode composes.
class DashboardBundleRef {
  const DashboardBundleRef({
    required this.bundleId,
    required this.source,
    this.url,
    this.aggregatorServerId,
    this.inlineDefinition,
  });

  final String bundleId;
  final BundleSource source;
  final String? url;
  final String? aggregatorServerId;
  final Map<String, dynamic>? inlineDefinition;
}

/// Materialized dashboard bundle loaded by [DashboardBundleLoader].
class DashboardBundle {
  const DashboardBundle({
    required this.id,
    required this.mainLayout,
    required this.slots,
    this.commonActions = const [],
  });

  final String id;
  final Map<String, dynamic> mainLayout;
  final List<SlotDefinition> slots;
  final List<Map<String, dynamic>> commonActions;
}

/// Resolved binding between a slot and a concrete device.
class SlotBinding {
  const SlotBinding({required this.slotId, required this.deviceId});
  final String slotId;
  final String deviceId;
}
