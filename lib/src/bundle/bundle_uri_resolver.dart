import 'package:mcp_bundle/mcp_bundle.dart' hide BundleLoadException, BundleLoader;

import '../exceptions.dart';
import '../logging/logger.dart';

/// Resolved target for a `bundle://` URI (MOD-BUNDLE-003).
class ResolvedBundleUri {
  const ResolvedBundleUri(this.target, this.mediaType);

  final Uri target;
  final String mediaType;
}

/// Resolves `bundle://` URIs into runtime-consumable URIs (MOD-BUNDLE-003,
/// FR-BUNDLE-003 / FR-APP-LOCAL-005, UI DSL v1.2 §5.3).
class BundleUriResolver {
  BundleUriResolver({
    String? bundleRootPath,
    AssetSection? assets,
    Logger? logger,
  })  : _bundleRootPath = bundleRootPath,
        _assets = assets,
        _logger = logger ?? NoopLogger();

  final String? _bundleRootPath;
  final AssetSection? _assets;
  final Logger _logger;

  static const _scheme = 'bundle';

  /// FR-BUNDLE-003
  ResolvedBundleUri resolve(String bundleUri) {
    final Uri uri;
    try {
      uri = Uri.parse(bundleUri);
    } catch (e) {
      throw BundleUriResolutionException(bundleUri, 'Malformed URI', cause: e);
    }

    if (uri.scheme != _scheme) {
      throw BundleUriResolutionException(
        bundleUri,
        'Not a bundle:// URI (scheme: ${uri.scheme})',
      );
    }

    final category = uri.host;
    final path = uri.pathSegments.join('/');
    final relPath = path.isEmpty ? category : '$category/$path';

    // Inline asset lookup via assets section.
    final assets = _assets;
    if (assets != null) {
      final asset = assets.getAsset(relPath) ?? assets.getAsset(path);
      if (asset != null) {
        if (asset.content != null) {
          final mime = asset.mimeType ?? _inferMediaType(asset.path);
          final encoding = asset.encoding;
          final dataUri = encoding == 'base64'
              ? Uri.parse('data:$mime;base64,${asset.content}')
              : Uri.dataFromString(
                  asset.content!,
                  mimeType: mime,
                );
          return ResolvedBundleUri(dataUri, mime);
        }
        if (asset.contentRef != null) {
          final refUri = Uri.parse(asset.contentRef!);
          if (refUri.hasScheme) {
            return ResolvedBundleUri(
              refUri,
              asset.mimeType ?? _inferMediaType(asset.path),
            );
          }
          if (_bundleRootPath != null) {
            return ResolvedBundleUri(
              Uri.file('$_bundleRootPath/${asset.contentRef}'),
              asset.mimeType ?? _inferMediaType(asset.path),
            );
          }
        }
      }
    }

    // Fallback: infer from bundle root path.
    if (_bundleRootPath != null) {
      return ResolvedBundleUri(
        Uri.file('$_bundleRootPath/$relPath'),
        _inferMediaType(relPath),
      );
    }

    throw BundleUriResolutionException(bundleUri, 'No mapping found');
  }

  /// Recursively rewrites `bundle://` strings inside a definition JSON tree.
  dynamic rewriteDefinition(dynamic node) {
    if (node is Map) {
      return <String, dynamic>{
        for (final entry in node.entries) entry.key: rewriteDefinition(entry.value),
      };
    }
    if (node is List) {
      return node.map(rewriteDefinition).toList();
    }
    if (node is String && node.startsWith('bundle://')) {
      try {
        return resolve(node).target.toString();
      } on BundleUriResolutionException catch (e) {
        _logger.warn('bundle.uri.resolve.miss', {'uri': node, 'reason': e.message});
        return node;
      }
    }
    return node;
  }

  String _inferMediaType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'svg':
        return 'image/svg+xml';
      case 'webp':
        return 'image/webp';
      case 'json':
        return 'application/json';
      case 'txt':
        return 'text/plain';
      case 'md':
        return 'text/markdown';
      default:
        return 'application/octet-stream';
    }
  }
}
