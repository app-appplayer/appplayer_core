import 'tenant_context.dart';

/// Host-injected interface resolving an app code into a [TenantContext].
abstract class TenantSource {
  /// Returns `null` when the app code is unknown.
  Future<TenantContext?> resolve(String appCode);
}
