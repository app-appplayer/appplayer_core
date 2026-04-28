import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    show MCPUIDSLVersion;
import 'package:mcp_bundle/mcp_bundle.dart' as mcpb;

import '../exceptions.dart';
import '../logging/logger.dart';
import 'installed_app_bundle.dart';

/// Wraps `mcp_bundle.McpBundleInstaller` so Core can expose a stable
/// install / uninstall / list API without leaking `mcp_bundle` types
/// (MOD-BUNDLE-005, FR-INSTALL-001~008).
class BundleInstallerAdapter {
  BundleInstallerAdapter({
    required this.installRoot,
    Logger? logger,
  }) : _logger = logger ?? NoopLogger();

  final String installRoot;
  final Logger _logger;

  static final mcpb.RuntimeDescriptor _runtime = mcpb.RuntimeDescriptor(
    version: MCPUIDSLVersion.current,
    features: const <String>{},
  );

  static const mcpb.TrustStore _trustStore = mcpb.EmptyTrustStore();

  Future<InstalledAppBundle> installFile(String filePath) async {
    return _run('file', () async {
      final installed = await mcpb.McpBundleInstaller.installFile(
        filePath,
        installRoot: installRoot,
        runtime: _runtime,
        trustStore: _trustStore,
      );
      return _toCore(installed);
    });
  }

  Future<InstalledAppBundle> installDirectory(String mbdPath) async {
    return _run('directory', () async {
      final installed = await mcpb.McpBundleInstaller.installDirectory(
        mbdPath,
        installRoot: installRoot,
        runtime: _runtime,
        trustStore: _trustStore,
      );
      return _toCore(installed);
    });
  }

  Future<InstalledAppBundle> installUrl(Uri url) async {
    return _run('url', () async {
      final installed = await mcpb.McpBundleInstaller.installUrl(
        url,
        installRoot: installRoot,
        runtime: _runtime,
        trustStore: _trustStore,
      );
      return _toCore(installed);
    });
  }

  Future<void> uninstall(String bundleId) async {
    _logger.info('bundle.uninstall', {'bundleId': bundleId});
    await mcpb.McpBundleInstaller.uninstall(installRoot, bundleId);
  }

  Future<List<InstalledAppBundle>> list() async {
    final installed = await mcpb.McpBundleInstaller.list(installRoot);
    _logger.debug('bundle.list', {'count': installed.length});
    return installed.map(_toCore).toList(growable: false);
  }

  Future<InstalledAppBundle> _run(
    String source,
    Future<InstalledAppBundle> Function() body,
  ) async {
    _logger.debug('bundle.install.start',
        {'source': source, 'installRoot': installRoot});
    try {
      final result = await body();
      _logger.info('bundle.install.success', {
        'bundleId': result.id,
        'version': result.version,
        'signer': result.signer,
        'installedAt': result.installedAt.toIso8601String(),
      });
      return result;
    } catch (e, st) {
      _logger.logError('bundle.install.fail', e, st, {'source': source});
      throw _wrap(e);
    }
  }

  InstalledAppBundle _toCore(mcpb.InstalledBundle b) => InstalledAppBundle(
        id: b.id,
        version: b.version,
        installedAt: b.installedAt,
        installPath: b.installPath,
        signer: b.signer,
      );

  BundleInstallException _wrap(Object e) {
    if (e is BundleInstallException) return e;
    final reason = _reasonFor(e);
    final bundleId = _bundleIdFor(e);
    return BundleInstallException(
      reason: reason,
      bundleId: bundleId,
      cause: e,
    );
  }

  BundleInstallReason _reasonFor(Object e) {
    if (e is mcpb.BundleNotFoundException) return BundleInstallReason.notFound;
    if (e is mcpb.BundleFormatException) return BundleInstallReason.format;
    if (e is mcpb.BundleIntegrityException) {
      return BundleInstallReason.integrity;
    }
    if (e is mcpb.BundleSignatureException) {
      return BundleInstallReason.signature;
    }
    if (e is mcpb.BundleCompatibilityException) {
      return BundleInstallReason.compatibility;
    }
    if (e is mcpb.BundleLimitException) return BundleInstallReason.limit;
    if (e is mcpb.BundleAlreadyInstalledException) {
      return BundleInstallReason.alreadyInstalled;
    }
    if (e is mcpb.BundleBusyException) return BundleInstallReason.busy;
    if (e is mcpb.BundleReadException) return BundleInstallReason.fetchError;
    return BundleInstallReason.unknown;
  }

  String? _bundleIdFor(Object e) {
    if (e is mcpb.BundleAlreadyInstalledException) return e.id;
    return null;
  }
}
