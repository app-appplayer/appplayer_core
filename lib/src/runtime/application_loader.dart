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
  /// [resources] lets a caller pass a resource list it has already fetched
  /// (e.g. for MCP Serving bundle-document detection) so the server is listed
  /// only once; when null the list is fetched here.
  Future<Map<String, dynamic>> load(
    Client client, {
    List<Resource>? resources,
  }) async {
    final List<Resource> resolved;
    if (resources != null) {
      resolved = resources;
    } else {
      try {
        resolved = await client.listResources();
      } catch (e, st) {
        throw _wrapLoad('listResources failed', e, st);
      }
    }

    _logger.debug('Resources listed', {'count': resolved.length});

    final appUri = pickAppUri(resolved);
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

  /// Promote a served UI definition to AppPlayer's standard app-execution
  /// structure: a `type:"application"` document with a single route pointing
  /// at [appUri]. A definition that is already an application passes through
  /// unchanged.
  ///
  /// Every app — even a one-page server board — must run as an application so
  /// the runtime mounts the routing pipeline: each route renders through
  /// `MCPPageWidget`, which frames the page in a Scaffold and lifts the page's
  /// own `title` into an AppBar (a bare page rendered directly gets neither).
  /// The application structure is also what makes the dashboard slot and
  /// navigation available. The visible name comes from the page `title` here,
  /// so a board that serves no `ui://app/info` metadata still shows its name —
  /// the app structure carries it, no separate metadata fetch required.
  Map<String, dynamic> wrapAsApplication(
    Map<String, dynamic> definition, {
    required String appUri,
  }) {
    if (definition['type'] == 'application') return definition;
    final title = definition['title'];
    return <String, dynamic>{
      'type': 'application',
      if (title is String && title.isNotEmpty) 'title': title,
      'routes': <String, dynamic>{'/': appUri},
      'initialRoute': '/',
    };
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

  /// Page loader that serves [cache] entries from memory and falls back to the
  /// live [client] for any other uri.
  ///
  /// The server-open path already reads the entry page (`ui://app`) once to
  /// detect its type before promoting it to an application ([wrapAsApplication]).
  /// Routing that page through the client again — a second read over a possibly
  /// dead link — is what surfaced "Failed to load page / Client is not
  /// initialized" on a screen with no way out. Feeding the already-parsed
  /// content back through the cache means the app's first frame renders from
  /// memory, so its AppBar (and its close/exit affordance) is always present,
  /// even if the connection dropped right after the initial load.
  PageLoader cachingPageLoaderFor(
    Client client,
    Map<String, Map<String, dynamic>> cache,
  ) {
    final base = pageLoaderFor(client);
    return (String uri) async {
      final cached = cache[uri];
      if (cached != null) {
        _logger.debug('Loading page from cache', {'uri': uri});
        return cached;
      }
      return base(uri);
    };
  }

  /// FR-APP-002 selection priority. Public so the server-open path can
  /// resolve the route target when promoting a bare page to a single-route
  /// application (see [wrapAsApplication]).
  String? pickAppUri(List<Resource> resources) {
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
