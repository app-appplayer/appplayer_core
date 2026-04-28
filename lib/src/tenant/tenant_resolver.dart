import '../exceptions.dart';
import '../logging/logger.dart';
import 'tenant_context.dart';
import 'tenant_source.dart';

/// Resolves app codes into [TenantContext] and guards allowlists
/// (MOD-TENANT-001, FR-TENANT-001~006).
class TenantResolver {
  TenantResolver({TenantSource? source, Logger? logger})
      : _source = source,
        _logger = logger ?? NoopLogger();

  final TenantSource? _source;
  final Logger _logger;
  TenantContext? _current;

  TenantContext? get current => _current;
  bool get isActive => _current != null;

  /// FR-TENANT-001, 002
  Future<TenantContext> apply(String appCode) async {
    if (_source == null) {
      throw TenantResolveException(
        appCode,
        'TenantSource not injected',
      );
    }
    _logger.info('Resolving tenant', {'appCode': appCode});
    final ctx = await _source!.resolve(appCode);
    if (ctx == null) {
      throw TenantResolveException(appCode, 'Tenant not found');
    }
    _current = ctx;
    _logger.info('Tenant applied', {
      'appCode': appCode,
      'servers': ctx.allowedServerIds.length,
      'bundles': ctx.allowedBundleIds.length,
    });
    return ctx;
  }

  /// FR-TENANT-005
  void clear() {
    _current = null;
    _logger.info('Tenant cleared');
  }

  /// FR-TENANT-003
  void assertAllowedServer(String serverId) {
    final ctx = _current;
    if (ctx == null) return;
    if (!ctx.allowedServerIds.contains(serverId)) {
      throw TenantAccessDeniedException(
        resource: 'server:$serverId',
        reason: 'Not in tenant allowlist',
      );
    }
  }

  /// FR-TENANT-004
  void assertAllowedBundle(String bundleId) {
    final ctx = _current;
    if (ctx == null) return;
    if (!ctx.allowedBundleIds.contains(bundleId)) {
      throw TenantAccessDeniedException(
        resource: 'bundle:$bundleId',
        reason: 'Not in tenant allowlist',
      );
    }
  }
}
