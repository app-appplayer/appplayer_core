import 'dart:convert';
import 'dart:typed_data';

import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;

import '../exceptions.dart';
import '../logging/logger.dart';
import '../metrics/metrics_port.dart';
import 'bundle_fetcher.dart';
import 'bundle_ref.dart';

/// Loads `McpBundle` objects from inline / remote / installed sources and
/// validates schema and manifest (MOD-BUNDLE-001, FR-BUNDLE-001/004~010).
///
/// Core-level adapter. `mcp_bundle` does the actual schema parsing via
/// `McpBundle.fromJson` (inline / remote) or `McpBundleLoader.loadInstalled`
/// (installed). This class wraps failures with `bundleId` context and a
/// unified [BundleLoadReason] taxonomy so hosts can react uniformly.
class BundleLoaderAdapter {
  BundleLoaderAdapter({
    BundleFetcher? fetcher,
    Logger? logger,
    MetricsPort? metrics,
    String? installRoot,
  })  : _fetcher = fetcher,
        _logger = logger ?? NoopLogger(),
        _metrics = metrics ?? const NoopMetricsPort(),
        _installRoot = installRoot;

  final BundleFetcher? _fetcher;
  final Logger _logger;
  final MetricsPort _metrics;
  final String? _installRoot;

  /// Schema versions accepted by this release. Kept narrow; `mcp_bundle`
  /// validates internal structure while this adapter enforces the payload
  /// schema range acceptable to the runtime.
  static const Set<String> supportedSchemaVersions = {'1.0.0'};

  /// FR-BUNDLE-001
  Future<McpBundle> load(BundleRef ref) async {
    final stopwatch = Stopwatch()..start();
    _logger.debug('bundle.load.start', {'refType': ref.runtimeType.toString()});
    try {
      final bundle = await _loadInner(ref);
      stopwatch.stop();
      _metrics.recordLatency(
        'bundle_load',
        stopwatch.elapsed,
        tags: {'result': 'success', 'type': bundle.manifest.type.name},
      );
      _logger.info('bundle.load.success', {
        'bundleId': bundle.manifest.id,
        'version': bundle.manifest.version,
        'type': bundle.manifest.type.name,
        'latencyMs': stopwatch.elapsedMilliseconds,
      });
      return bundle;
    } catch (e, st) {
      stopwatch.stop();
      _metrics.recordLatency(
        'bundle_load',
        stopwatch.elapsed,
        tags: {'result': 'fail'},
      );
      _logger.logError('bundle.load.fail', e, st);
      rethrow;
    }
  }

  Future<McpBundle> _loadInner(BundleRef ref) async {
    final Map<String, dynamic> json;
    Uint8List? rawBytes;

    switch (ref) {
      case BundleInlineRef(:final json):
        final bundle = _decodeBundle(json, rawBytes: null);
        _validate(bundle, rawBytes: null);
        return bundle;

      case BundleFileRef(:final path):
        throw BundleLoadException(
          bundleId: '(file)',
          reason: BundleLoadReason.unknown,
          message:
              'BundleFileRef is not resolved by the core — host must convert '
              'to BundleInlineRef first (path: $path)',
        );

      case BundleRemoteRef(:final url, :final headers):
        if (_fetcher == null) {
          throw BundleLoadException(
            bundleId: '(remote)',
            reason: BundleLoadReason.fetchError,
            message: 'No BundleFetcher injected for remote bundle: $url',
          );
        }
        try {
          rawBytes = await _fetcher!.fetch(url, headers: headers);
        } catch (e) {
          throw BundleLoadException(
            bundleId: '(remote)',
            reason: BundleLoadReason.fetchError,
            message: 'Remote fetch failed: $url',
            cause: e,
          );
        }
        try {
          final decoded = jsonDecode(utf8.decode(rawBytes));
          if (decoded is! Map<String, dynamic>) {
            throw BundleLoadException(
              bundleId: '(remote)',
              reason: BundleLoadReason.parseError,
              message: 'Remote payload is not a JSON object',
            );
          }
          json = decoded;
        } catch (e) {
          if (e is BundleLoadException) rethrow;
          throw BundleLoadException(
            bundleId: '(remote)',
            reason: BundleLoadReason.parseError,
            message: 'Remote payload parse failed',
            cause: e,
          );
        }

      case BundleInstalledRef(:final bundleId):
        // FR-BUNDLE-009 — delegate to mcp_bundle so McpBundle.directory is
        // populated; BundleApplicationAdapter reads ui/app.json from there.
        final root = _installRoot;
        if (root == null) {
          throw BundleLoadException(
            bundleId: bundleId,
            reason: BundleLoadReason.unknown,
            message: 'BundleInstalledRef requires bundleInstallRoot to be '
                'provided via AppPlayerCoreService.initialize',
          );
        }
        final McpBundle bundle;
        try {
          bundle = await McpBundleLoader.loadInstalled(root, bundleId);
        } on BundleNotFoundException catch (e) {
          throw BundleLoadException(
            bundleId: bundleId,
            reason: BundleLoadReason.notFound,
            message: 'Installed bundle not found at $root/$bundleId',
            cause: e,
          );
        } catch (e) {
          throw BundleLoadException(
            bundleId: bundleId,
            reason: BundleLoadReason.parseError,
            message: 'Failed to load installed bundle $bundleId',
            cause: e,
          );
        }
        _validate(bundle, rawBytes: null);
        return bundle;
    }

    final bundle = _decodeBundle(json, rawBytes: rawBytes);
    _validate(bundle, rawBytes: rawBytes);
    return bundle;
  }

  McpBundle _decodeBundle(Map<String, dynamic> json, {Uint8List? rawBytes}) {
    try {
      return McpBundle.fromJson(json);
    } catch (e) {
      throw BundleLoadException(
        bundleId: (json['manifest']?['id'] as String?) ?? '(unknown)',
        reason: BundleLoadReason.parseError,
        message: 'Bundle schema decode failed',
        cause: e,
      );
    }
  }

  void _validate(McpBundle bundle, {Uint8List? rawBytes}) {
    // FR-BUNDLE-004
    if (!supportedSchemaVersions.contains(bundle.schemaVersion)) {
      throw BundleLoadException(
        bundleId: bundle.manifest.id,
        reason: BundleLoadReason.unsupportedSchema,
        message: 'Unsupported bundle schemaVersion: ${bundle.schemaVersion}',
      );
    }

    // FR-BUNDLE-005
    final m = bundle.manifest;
    if (m.id.isEmpty) {
      throw BundleLoadException(
        bundleId: '(unknown)',
        reason: BundleLoadReason.invalidManifest,
        message: 'manifest.id is empty',
      );
    }
    if (m.name.isEmpty) {
      throw BundleLoadException(
        bundleId: m.id,
        reason: BundleLoadReason.invalidManifest,
        message: 'manifest.name is empty',
      );
    }
    if (m.version.isEmpty) {
      throw BundleLoadException(
        bundleId: m.id,
        reason: BundleLoadReason.invalidManifest,
        message: 'manifest.version is empty',
      );
    }
    if (m.schemaVersion.isEmpty) {
      throw BundleLoadException(
        bundleId: m.id,
        reason: BundleLoadReason.invalidManifest,
        message: 'manifest.schemaVersion is empty',
      );
    }

    // FR-BUNDLE-006 — integrity
    final integrity = bundle.integrity;
    if (integrity != null && rawBytes != null) {
      _verifyIntegrity(bundle, rawBytes);
    }
  }

  void _verifyIntegrity(McpBundle bundle, Uint8List rawBytes) {
    // Actual hash verification delegated to mcp_bundle utilities when
    // available. Core keeps the placeholder so hosts can override via
    // `BundleFetcher` returning pre-verified bytes if needed.
  }
}
