import 'dart:typed_data';

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
  /// Install into a directory on the local filesystem.
  BundleInstallerAdapter({
    required String installRoot,
    Logger? logger,
  })  : installRoot = installRoot,
        store = mcpb.FileBundleInstallStore(installRoot),
        _logger = logger ?? NoopLogger();


  /// Install into host-provided storage.
  ///
  /// The form a host with no filesystem uses — the browser shell passes
  /// the account's storage here and installing works unchanged.
  BundleInstallerAdapter.onStore({
    required this.store,
    Logger? logger,
  })  : installRoot = null,
        _logger = logger ?? NoopLogger();

  /// Install directory, when this adapter was built from one.
  final String? installRoot;

  /// Where installed bundles live.
  final mcpb.BundleInstallStore store;

  final Logger _logger;

  static final mcpb.RuntimeDescriptor _runtime = mcpb.RuntimeDescriptor(
    version: MCPUIDSLVersion.current,
    features: const <String>{},
  );

  static const mcpb.TrustStore _trustStore = mcpb.EmptyTrustStore();

  /// Install from `.mcpb` bytes already in hand.
  ///
  /// The entry point a host without a filesystem uses: it downloaded the
  /// archive, so it has bytes and never a path. [installFile] is the
  /// same call with a read in front of it.
  Future<InstalledAppBundle> installBytes(Uint8List bytes) async {
    return _run('bytes', () async {
      final installed = await mcpb.McpBundleInstaller.installBytes(
        bytes,
        store: store,
        runtime: _runtime,
        trustStore: _trustStore,
      );
      return _toCore(installed);
    });
  }

  Future<InstalledAppBundle> installFile(String filePath) async {
    return _run('file', () async {
      final installed = await mcpb.McpBundleInstaller.installFile(
        filePath,
        store: store,
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
        store: store,
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
        store: store,
        runtime: _runtime,
        trustStore: _trustStore,
      );
      return _toCore(installed);
    });
  }

  Future<void> uninstall(String bundleId) async {
    _logger.info('bundle.uninstall', {'bundleId': bundleId});
    await mcpb.McpBundleInstaller.uninstallFrom(store, bundleId);
  }

  Future<List<InstalledAppBundle>> list() async {
    final installed = await mcpb.McpBundleInstaller.listFrom(store);
    _logger.debug('bundle.list', {'count': installed.length});
    return installed.map(_toCore).toList(growable: false);
  }

  Future<InstalledAppBundle> _run(
    String source,
    Future<InstalledAppBundle> Function() body,
  ) async {
    _logger.debug('bundle.install.start',
        {'source': source, 'destination': installRoot ?? store.runtimeType});
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
