import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    show MCPUIDSLVersion;
import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;

import '../exceptions.dart';
import '../logging/logger.dart';
import '../model/application_definition.dart';
import 'bundle_entry_point.dart';
import 'bundle_uri_resolver.dart';

/// Converts `McpBundle` into a runtime-ready `ApplicationDefinition`
/// (MOD-BUNDLE-004, FR-APP-LOCAL-004~008).
///
/// The bundle is treated as a filesystem snapshot of the server's
/// resource URI space — `ui/app.json` is the application definition and
/// `ui://<path>` URIs are resolved by reading `ui/<path>.json`. **All
/// UI file I/O goes through `bundle.uiResources`** (mcp_bundle's
/// reserved-folder API); `dart:io` is never imported here. mcp_bundle
/// owns the on-disk layout, this adapter only translates between bundle
/// bytes and `ApplicationDefinition`.
///
/// No shape translation happens at this layer — whatever the
/// DSL-serving pipeline produces is what the bundle stores and what
/// the runtime consumes.
class BundleApplicationAdapter {
  BundleApplicationAdapter({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;

  /// FR-APP-LOCAL-004~008
  Future<ApplicationDefinition> adapt(
    McpBundle bundle,
    BundleEntryPoint entry, {
    required BundleUriResolver uriResolver,
  }) async {
    _assertRuntimeCompatibility(bundle.manifest);

    final bundleId = bundle.manifest.id;
    if (bundle.directory == null) {
      throw BundleAdaptException(
        bundleId: bundleId,
        reason: BundleAdaptReason.unsupportedEntryPoint,
        message:
            'Bundle has no filesystem root — inline / remote refs must '
            'be materialised to a directory before adapting',
      );
    }

    final ui = bundle.uiResources;
    if (!await ui.exists('app.json')) {
      throw BundleAdaptException(
        bundleId: bundleId,
        reason: BundleAdaptReason.unsupportedEntryPoint,
        message:
            'ui/app.json not found in installed bundle ${bundle.directory} '
            '— the bundle likely predates the filesystem-snapshot layout. '
            'Delete the app entry in the launcher and reinstall from '
            'the .mcpb. Available ui/* files: '
            '${await ui.list(extension: '.json')}',
      );
    }

    final Map<String, dynamic> definitionJson;
    try {
      final raw = await ui.readJson('app.json');
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('ui/app.json must be a JSON object');
      }
      definitionJson = raw;
    } catch (e, st) {
      _logger.logError('bundle.adapter.app_json_parse', e, st,
          {'bundleId': bundleId});
      throw BundleAdaptException(
        bundleId: bundleId,
        reason: BundleAdaptReason.unsupportedEntryPoint,
        message: 'ui/app.json parse failed: $e',
      );
    }

    final Map<String, dynamic> rewritten;
    try {
      rewritten =
          uriResolver.rewriteDefinition(definitionJson) as Map<String, dynamic>;
    } on BundleUriResolutionException catch (e, st) {
      _logger.logError('bundle.adapter.uri_resolution', e, st,
          {'bundleId': bundleId});
      throw BundleAdaptException(
        bundleId: bundleId,
        reason: BundleAdaptReason.uriResolution,
        cause: e,
      );
    }

    final pageLoader = _pageLoaderFor(bundle, uriResolver);

    _logger.debug('bundle.adapter.result', {
      'bundleId': bundleId,
      'entry': entry.toString(),
      'routes':
          (rewritten['routes'] as Map?)?.length ?? 0,
    });

    return ApplicationDefinition(
      json: rewritten,
      pageLoader: pageLoader,
      sourceKind: ApplicationSourceKind.localBundle,
      appId: bundleId,
    );
  }

  /// Build the on-demand page loader. Resolves `ui://<path>` URIs to
  /// JSON files under the bundle's `ui/` reserved folder, going through
  /// `bundle.uiResources` so path safety, JSON validation, and
  /// not-found errors are handled uniformly.
  PageLoaderFn _pageLoaderFor(McpBundle bundle, BundleUriResolver resolver) {
    return (String uri) async {
      final relative = _uriToUiRelativePath(uri);
      if (relative == null) {
        throw ResourceNotFoundException('Unsupported page URI: $uri');
      }

      final dynamic decoded;
      try {
        decoded = await bundle.uiResources.readJson(relative);
      } on BundleResourceNotFoundException {
        throw ResourceNotFoundException(
          'Bundle page not found: $uri (looked up ui/$relative)',
        );
      } on BundleResourceParseException catch (e) {
        throw ResourceNotFoundException(
          'Bundle page parse failed: $uri ($e)',
        );
      }

      if (decoded is! Map<String, dynamic>) {
        throw ResourceNotFoundException(
          'Bundle page is not a JSON object: $uri',
        );
      }
      return resolver.rewriteDefinition(decoded) as Map<String, dynamic>;
    };
  }

  /// Map `ui://<path>` to `<path>.json` (relative to the `ui/` folder)
  /// or `bundle://ui/<path>` to the same. Returns `null` for unsupported
  /// schemes — `bundle://` URIs that target other reserved folders are
  /// not page resources and must be handled by their own adapters
  /// (`assetResources`, `skillResources`, etc.).
  String? _uriToUiRelativePath(String uri) {
    const uiPrefix = 'ui://';
    const bundleUiPrefix = 'bundle://ui/';
    if (uri.startsWith(uiPrefix)) {
      final rel = uri.substring(uiPrefix.length);
      if (rel.isEmpty) return null;
      return '$rel.json';
    }
    if (uri.startsWith(bundleUiPrefix)) {
      final rel = uri.substring(bundleUiPrefix.length);
      if (rel.isEmpty) return null;
      return rel.endsWith('.json') ? rel : '$rel.json';
    }
    return null;
  }

  void _assertRuntimeCompatibility(BundleManifest manifest) {
    final required = manifest.minRuntimeVersion;
    if (required == null || required.isEmpty) return;

    if (!MCPUIDSLVersion.isCompatible(required)) {
      throw BundleAdaptException(
        bundleId: manifest.id,
        reason: BundleAdaptReason.incompatibleRuntimeVersion,
        message:
            'required=$required, runtime supports ${MCPUIDSLVersion.supported}',
      );
    }
  }
}
