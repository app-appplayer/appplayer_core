import 'dart:convert';

import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../exceptions.dart';
import '../logging/logger.dart';
import '../model/application_definition.dart';

/// Page-loader closure accepted by `MCPUIRuntime.initialize`.
typedef PageLoader = Future<Map<String, dynamic>> Function(String uri);

/// Discovers and loads application definitions from an MCP server
/// (MOD-RUNTIME-002, FR-APP-001~003, FR-APP-ONLINE-001~005).
class ApplicationLoader {
  ApplicationLoader({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;

  /// FR-APP-ONLINE-001~005 — Returns a source-kind-labelled
  /// [ApplicationDefinition] that converges with the Local Bundle path
  /// emitted by `BundleApplicationAdapter`.
  Future<ApplicationDefinition> loadOnline(
    Client client, {
    required String serverId,
  }) async {
    final json = await load(client);
    return ApplicationDefinition(
      json: json,
      pageLoader: pageLoaderFor(client),
      sourceKind: ApplicationSourceKind.online,
      appId: serverId,
    );
  }

  /// FR-APP-ONLINE-001~004 — Raw JSON form used internally by
  /// [loadOnline] and by legacy callers.
  Future<Map<String, dynamic>> load(Client client) async {
    final List<Resource> resources;
    try {
      resources = await client.listResources();
    } catch (e, st) {
      throw _wrapLoad('listResources failed', e, st);
    }

    _logger.debug('Resources listed', {'count': resources.length});

    final appUri = _pickAppUri(resources);
    if (appUri == null) {
      throw ResourceNotFoundException('No UI resources found');
    }

    _logger.info('Loading application', {'uri': appUri});

    final ReadResourceResult resource;
    try {
      resource = await client.readResource(appUri);
    } catch (e, st) {
      throw _wrapLoad('readResource failed', e, st);
    }

    if (resource.contents.isEmpty) {
      throw DefinitionParseException(appUri);
    }
    final text = resource.contents.first.text;
    if (text == null) {
      throw DefinitionParseException(appUri);
    }

    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw DefinitionParseException(appUri);
      }
      return decoded;
    } on DefinitionParseException {
      rethrow;
    } catch (e) {
      throw DefinitionParseException(appUri, cause: e);
    }
  }

  /// FR-APP-006
  PageLoader pageLoaderFor(Client client) {
    return (String uri) async {
      _logger.debug('Loading page', {'uri': uri});
      final page = await client.readResource(uri);
      if (page.contents.isEmpty) return <String, dynamic>{};
      final text = page.contents.first.text ?? '{}';
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
    };
  }

  /// FR-APP-002 selection priority.
  String? _pickAppUri(List<Resource> resources) {
    if (resources.isEmpty) return null;

    for (final r in resources) {
      if (r.uri == 'ui://app') return r.uri;
      if (r.uri.endsWith('/app')) return r.uri;
      final name = r.name.toLowerCase();
      if (name.contains('app') || name.contains('main')) return r.uri;
    }
    for (final r in resources) {
      if (r.uri.startsWith('ui://')) return r.uri;
    }
    return resources.first.uri;
  }

  LoadException _wrapLoad(String message, Object cause, StackTrace st) {
    _logger.logError(message, cause, st);
    return _GenericLoadException(message, cause);
  }
}

class _GenericLoadException extends LoadException {
  _GenericLoadException(super.message, Object cause) : super(cause: cause);
}
