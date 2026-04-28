import 'dart:convert';

import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../exceptions.dart';
import '../logging/logger.dart';

/// Locates and parses a device's summary view definition
/// (MOD-DASH-004, FR-DASH-005~006).
class SummaryViewResolver {
  SummaryViewResolver({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;

  Future<Map<String, dynamic>> fetch(
    Client client, {
    String? customUri,
  }) async {
    if (customUri != null) {
      _logger.debug('Fetching summary by customUri', {'uri': customUri});
      return _readAndParse(client, customUri);
    }

    final resources = await client.listResources();

    for (final r in resources) {
      if (r.uri == 'ui://views/summary') {
        return _readAndParse(client, r.uri);
      }
    }
    for (final r in resources) {
      if (r.uri.toLowerCase().contains('summary')) {
        return _readAndParse(client, r.uri);
      }
    }

    // Fallback: build a minimal summary from manifest.
    Resource? manifest;
    for (final r in resources) {
      if (r.uri == 'ui://manifest' ||
          r.name.toLowerCase().contains('manifest')) {
        manifest = r;
        break;
      }
    }
    if (manifest != null) {
      final data = await _readAndParse(client, manifest.uri);
      return _buildFallbackSummary(data);
    }

    throw ResourceNotFoundException('No summary view available');
  }

  Future<Map<String, dynamic>> _readAndParse(
    Client client,
    String uri,
  ) async {
    final res = await client.readResource(uri);
    if (res.contents.isEmpty) return <String, dynamic>{};
    final text = res.contents.first.text ?? '{}';
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{};
    } catch (e) {
      throw DefinitionParseException(uri, cause: e);
    }
  }

  Map<String, dynamic> _buildFallbackSummary(
      Map<String, dynamic> manifest) {
    final name = manifest['name'] ?? 'Unknown device';
    final id = manifest['id'] ?? 'unknown';
    return {
      'type': 'page',
      'content': {
        'type': 'card',
        'children': [
          {'type': 'text', 'value': name},
          {'type': 'badge', 'value': '{{status}}'},
        ],
      },
      'mcpRuntime': {
        'runtime': {
          'id': '$id-fallback-summary',
          'domain': 'appplayer.dashboard.auto',
          'version': '0.0.0',
        },
      },
    };
  }
}
