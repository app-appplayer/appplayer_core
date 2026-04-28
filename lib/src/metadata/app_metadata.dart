/// Application metadata aggregated from `ui://app/info` (Online) or the
/// bundle manifest (Local Bundle) — MOD-MODEL-005, FR-META-*.
class AppMetadata {
  const AppMetadata({
    required this.appId,
    required this.sourceKind,
    required this.name,
    required this.version,
    this.description,
    this.iconUri,
    this.splashUri,
    this.screenshots = const [],
    this.category,
    this.publisher,
    this.homepage,
    this.privacyPolicy,
    this.extra = const {},
  });

  /// `serverId` (Online) or `bundle.manifest.id` (Local Bundle).
  final String appId;

  /// `'online'` or `'localBundle'`.
  final String sourceKind;

  final String name;
  final String version;
  final String? description;
  final String? iconUri;
  final String? splashUri;
  final List<String> screenshots;
  final String? category;
  final String? publisher;
  final String? homepage;
  final String? privacyPolicy;

  /// Raw payload for fields the sink may want to inspect (manifest.extensions
  /// or the full `ui://app/info` JSON).
  final Map<String, dynamic> extra;
}
