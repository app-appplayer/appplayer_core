import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;
import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../bundle/bundle_uri_resolver.dart';
import '../logging/logger.dart';
import '../metadata/app_metadata.dart';
import '../metadata/app_metadata_sink.dart';

/// Fetches and publishes `AppMetadata` from Online / Local Bundle sources.
class AppMetadataProvider {
  AppMetadataProvider({
    AppMetadataSink? sink,
    Logger? logger,
  })  : _sink = sink,
        _logger = logger ?? NoopLogger();

  final AppMetadataSink? _sink;
  final Logger _logger;

  static const String wellKnownUri = 'ui://app/info';

  /// FR-META-001, 002 — best-effort Online fetch.
  ///
  /// The `ui://app/info` read fires right after the connection handshake, so
  /// the first attempt can race a cold remote server or a not-yet-warm
  /// streamable-HTTP response channel and come back empty/erroring. When the
  /// caller knows the resource actually exists (it was in `listResources`),
  /// pass [retries] > 0 so a transient miss is retried with a short backoff
  /// instead of silently yielding null — the launcher tile would otherwise
  /// keep its fallback name until the user re-enters the app enough times to
  /// hit a lucky timing. A genuine miss (resource absent, malformed payload)
  /// still returns null on the first pass without burning retries.
  Future<AppMetadata?> fetchFromServer(
    Client client,
    String serverId, {
    int retries = 0,
    Duration retryDelay = const Duration(milliseconds: 300),
  }) async {
    for (var attempt = 0; attempt <= retries; attempt++) {
      final (metadata, transient) = await _tryFetch(client, serverId, attempt);
      if (metadata != null) return metadata;
      // Only a transient failure (empty/error) is worth retrying; a
      // definitive miss (payload present but not an object) is not.
      if (!transient || attempt == retries) return null;
      await Future<void>.delayed(retryDelay);
    }
    return null;
  }

  /// Returns the parsed metadata (or null) and whether the miss looked
  /// transient (empty contents / read threw) — the signal the retry loop
  /// uses. A malformed-but-present payload is a definitive miss (not
  /// transient): retrying would not help.
  Future<(AppMetadata?, bool)> _tryFetch(
    Client client,
    String serverId,
    int attempt,
  ) async {
    try {
      final result = await client.readResource(wellKnownUri);
      if (result.contents.isEmpty) {
        _logger.debug('metadata.online.fetch.miss',
            {'serverId': serverId, 'attempt': attempt, 'reason': 'empty'});
        return (null, true);
      }
      final text = result.contents.first.text;
      if (text == null || text.isEmpty) {
        return (null, true);
      }

      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        _logger.warn('metadata.online.parse.fail', {
          'serverId': serverId,
          'reason': 'payload is not an object',
        });
        return (null, false);
      }

      final metadata = _fromJson(serverId, decoded);
      _logger.info('metadata.online.fetch.success', {
        'serverId': serverId,
        'name': metadata.name,
        'attempt': attempt,
      });
      return (metadata, false);
    } catch (e) {
      _logger.debug('metadata.online.fetch.miss', {
        'serverId': serverId,
        'attempt': attempt,
        'cause': e.toString(),
      });
      return (null, true);
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
