import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;
import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../bundle/bundle_uri_resolver.dart';
import '../logging/logger.dart';
import '../metadata/app_metadata.dart';
import '../metadata/app_metadata_sink.dart';

/// Fetches and publishes `AppMetadata` from Online / Local Bundle sources
/// (MOD-RUNTIME-006, FR-META-001~005, UI DSL v1.2 §6.2).
class AppMetadataProvider {
  AppMetadataProvider({
    AppMetadataSink? sink,
    Logger? logger,
  })  : _sink = sink,
        _logger = logger ?? NoopLogger();

  final AppMetadataSink? _sink;
  final Logger _logger;

  static const String _wellKnownUri = 'ui://app/info';

  /// FR-META-001, 002 — best-effort Online fetch.
  Future<AppMetadata?> fetchFromServer(Client client, String serverId) async {
    try {
      final result = await client.readResource(_wellKnownUri);
      if (result.contents.isEmpty) {
        _logger.debug('metadata.online.fetch.miss', {'serverId': serverId});
        return null;
      }
      final text = result.contents.first.text;
      if (text == null || text.isEmpty) {
        return null;
      }

      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        _logger.warn('metadata.online.parse.fail', {
          'serverId': serverId,
          'reason': 'payload is not an object',
        });
        return null;
      }

      final metadata = _fromJson(serverId, decoded);
      _logger.info('metadata.online.fetch.success', {
        'serverId': serverId,
        'name': metadata.name,
      });
      return metadata;
    } catch (e) {
      _logger.debug('metadata.online.fetch.miss', {
        'serverId': serverId,
        'cause': e.toString(),
      });
      return null;
    }
  }

  /// FR-META-003 — extract metadata from a bundle manifest.
  AppMetadata fromBundle(McpBundle bundle, BundleUriResolver uriResolver) {
    String? resolveUri(String? raw) {
      if (raw == null) return null;
      if (!raw.startsWith('bundle://')) return raw;
      try {
        return uriResolver.resolve(raw).target.toString();
      } catch (e) {
        _logger.warn('metadata.bundle.uri.miss', {'uri': raw});
        return raw;
      }
    }

    final m = bundle.manifest;
    return AppMetadata(
      appId: m.id,
      sourceKind: 'localBundle',
      name: m.name,
      version: m.version,
      description: m.description,
      iconUri: resolveUri(m.icon),
      splashUri: resolveUri(m.splash?.image),
      screenshots:
          m.screenshots.map((s) => resolveUri(s) ?? s).toList(growable: false),
      category: m.category?.name,
      publisher: m.publisher?.name,
      homepage: m.homepage,
      privacyPolicy: m.privacyPolicy,
      extra: m.metadata,
    );
  }

  /// FR-META-004, 005 — deliver to sink, swallow sink failures.
  Future<void> publish(AppMetadata? metadata) async {
    if (metadata == null) return;
    final sink = _sink;
    if (sink == null) return;
    try {
      await sink.onMetadata(metadata);
      _logger.debug('metadata.sink.deliver', {'appId': metadata.appId});
    } catch (e, st) {
      _logger.warn('metadata.sink.fail', {
        'appId': metadata.appId,
        'cause': e.toString(),
      });
      _logger.logError('metadata.sink.fail', e, st);
    }
  }

  AppMetadata _fromJson(String serverId, Map<String, dynamic> json) {
    return AppMetadata(
      appId: serverId,
      sourceKind: 'online',
      name: (json['name'] as String?) ?? serverId,
      version: (json['version'] as String?) ?? '0.0.0',
      description: json['description'] as String?,
      iconUri: json['icon'] as String?,
      splashUri: json['splash'] is Map
          ? (json['splash'] as Map)['image'] as String?
          : null,
      screenshots: (json['screenshots'] as List?)?.cast<String>() ?? const [],
      category: json['category'] is Map
          ? (json['category'] as Map)['name'] as String?
          : json['category'] as String?,
      publisher: json['publisher'] is Map
          ? (json['publisher'] as Map)['name'] as String?
          : json['publisher'] as String?,
      homepage: json['homepage'] as String?,
      privacyPolicy: json['privacyPolicy'] as String?,
      extra: json,
    );
  }
}
