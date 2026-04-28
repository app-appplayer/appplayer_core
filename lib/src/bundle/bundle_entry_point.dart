/// Bundle entry point category (MOD-MODEL-005).
enum BundleEntryType { ui, flow, skill }

class BundleEntryPoint {
  const BundleEntryPoint(this.type, this.id);

  final BundleEntryType type;
  final String id;

  @override
  String toString() => '${_typeName(type)}.$id';

  static String _typeName(BundleEntryType t) {
    switch (t) {
      case BundleEntryType.ui:
        return 'ui';
      case BundleEntryType.flow:
        return 'flow';
      case BundleEntryType.skill:
        return 'skill';
    }
  }
}
