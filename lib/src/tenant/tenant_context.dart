/// Resolved tenant context (MOD-MODEL-003).
class TenantContext {
  const TenantContext({
    required this.appCode,
    required this.allowedServerIds,
    required this.allowedBundleIds,
    this.branding = const {},
    this.policies = const {},
  });

  final String appCode;
  final Set<String> allowedServerIds;
  final Set<String> allowedBundleIds;
  final Map<String, dynamic> branding;
  final Map<String, dynamic> policies;
}
