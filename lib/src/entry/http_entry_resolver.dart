/// The default resolver client: dereference an entry code over HTTPS
/// (platform spec 19 §2.1 resolver, §4.1).
///
/// The transport is injected rather than depended on, so this package gains no
/// HTTP dependency and a host can route the request through whatever client it
/// already ships — the same reason bundle fetching is injected.
library;

import 'dart:convert';

import '../logging/logger.dart';
import 'entry_pipeline.dart';
import 'entry_target.dart';

/// Performs the request. Returns the response body, or throws.
///
/// [headers] carries the locale so the issuer's own words come back in the
/// viewer's language (§4.1.2).
typedef EntryFetch = Future<String> Function(
  Uri url, {
  Map<String, String> headers,
});

/// Resolves an entry code against an HTTPS endpoint.
class HttpEntryResolver implements EntryResolverPort {
  HttpEntryResolver({
    required Uri endpoint,
    required EntryFetch fetch,
    Logger? logger,
  })  : _endpoint = endpoint,
        _fetch = fetch,
        _logger = logger ?? NoopLogger() {
    if (_endpoint.scheme != 'https') {
      // A resolver reached over plain http can be answered by anyone on the
      // path, and its answer decides what the viewer is shown and what
      // authority they are handed.
      throw ArgumentError.value(
        endpoint.toString(),
        'endpoint',
        'entry resolver endpoint must be https',
      );
    }
  }

  final Uri _endpoint;
  final EntryFetch _fetch;
  final Logger _logger;

  @override
  Future<EntryTarget> resolve(String code, {required String locale}) async {
    // The code is a path segment, not a query value: it is an identifier of a
    // resource, and encoding it keeps a partitioned code space intact.
    final url = _endpoint.replace(
      pathSegments: <String>[
        ..._endpoint.pathSegments.where((s) => s.isNotEmpty),
        ...code.split('/').where((s) => s.isNotEmpty),
      ],
    );

    try {
      final body = await _fetch(
        url,
        headers: <String, String>{
          'accept': 'application/json',
          'accept-language': locale,
        },
      );
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return EntryTargetCodec.unreachable('malformed resolver response');
      }
      return EntryTargetCodec.fromJson(decoded);
    } catch (e) {
      // A resolver we cannot reach is not an entry we may guess at. The host
      // renders a gate that says so; it never proceeds on an assumption.
      _logger.warn('entry.resolve.failed', <String, dynamic>{
        'url': url.toString(),
        'error': e.toString(),
      });
      return EntryTargetCodec.unreachable('resolver unreachable');
    }
  }
}
