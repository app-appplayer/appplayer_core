import 'dart:convert';

import '../connection/connection_manager.dart';
import '../exceptions.dart';
import '../logging/logger.dart';
import 'dashboard_bundle.dart';

/// Host-injected fetcher for market/URL bundles.
abstract class HttpBundleFetcher {
  Future<Map<String, dynamic>> fetch(String url);
}

/// Loads dashboard bundles from market URL, inline, Aggregator server,
/// or synthesizes a grid fallback (MOD-DASH-002, FR-DASH-001~003).
class DashboardBundleLoader {
  DashboardBundleLoader({
    required ConnectionManager conn,
    HttpBundleFetcher? httpFetcher,
    Logger? logger,
  })  : _conn = conn,
        _httpFetcher = httpFetcher,
        _logger = logger ?? NoopLogger();

  final ConnectionManager _conn;
  final HttpBundleFetcher? _httpFetcher;
  final Logger _logger;

  Future<DashboardBundle> load(
    DashboardBundleRef ref, {
    required List<String> connectedDevices,
  }) async {
    switch (ref.source) {
      case BundleSource.inline:
        final def = ref.inlineDefinition;
        if (def == null) {
          throw DashboardBundleLoadException(
              ref.bundleId, 'inline definition missing');
        }
        return _parse(ref.bundleId, def);

      case BundleSource.marketUrl:
        final url = ref.url;
        final fetcher = _httpFetcher;
        if (fetcher == null) {
          throw DashboardBundleLoadException(
              ref.bundleId, 'httpFetcher not injected');
        }
        if (url == null) {
          throw DashboardBundleLoadException(ref.bundleId, 'url missing');
        }
        try {
          final json = await fetcher.fetch(url);
          return _parse(ref.bundleId, json);
        } catch (e) {
          throw DashboardBundleLoadException(ref.bundleId, 'fetch failed',
              cause: e);
        }

      case BundleSource.aggregatorServer:
        final serverId = ref.aggregatorServerId;
        if (serverId == null) {
          throw DashboardBundleLoadException(
              ref.bundleId, 'aggregatorServerId missing');
        }
        final conn = _conn.getConnection(serverId);
        final client = conn?.client;
        if (client == null) {
          throw DashboardBundleLoadException(
              ref.bundleId, 'Aggregator not connected');
        }
        try {
          final resources = await client.listResources();
          final bundleUri = _pickBundleUri(resources, ref.bundleId);
          if (bundleUri == null) {
            throw DashboardBundleLoadException(
                ref.bundleId, 'Bundle resource not found');
          }
          final res = await client.readResource(bundleUri);
          if (res.contents.isEmpty) {
            throw DashboardBundleLoadException(ref.bundleId, 'Empty resource');
          }
          final text = res.contents.first.text ?? '{}';
          final json = jsonDecode(text);
          if (json is! Map<String, dynamic>) {
            throw DashboardBundleLoadException(
                ref.bundleId, 'Invalid JSON object');
          }
          return _parse(ref.bundleId, json);
        } on DashboardBundleLoadException {
          rethrow;
        } catch (e) {
          throw DashboardBundleLoadException(ref.bundleId, 'Aggregator fetch failed',
              cause: e);
        }

      case BundleSource.synthesized:
        return _synthesize(ref.bundleId, connectedDevices);
    }
  }

  String? _pickBundleUri(Iterable<dynamic> resources, String bundleId) {
    for (final r in resources) {
      final uri = r.uri as String;
      if (uri.contains(bundleId)) return uri;
    }
    for (final r in resources) {
      final uri = r.uri as String;
      if (uri.contains('dashboard')) return uri;
    }
    return null;
  }

  DashboardBundle _synthesize(
    String bundleId,
    List<String> deviceIds,
  ) {
    _logger.debug('Synthesizing bundle',
        {'bundleId': bundleId, 'devices': deviceIds.length});

    final children = <Map<String, dynamic>>[];
    final slots = <SlotDefinition>[];
    for (var i = 0; i < deviceIds.length; i++) {
      final slotId = 'slot-$i';
      children.add({'type': 'slot', 'slotId': slotId});
      slots.add(SlotDefinition(
        slotId: slotId,
        binding: SlotBindingRule.explicit(deviceIds[i]),
      ));
    }

    final mainLayout = <String, dynamic>{
      'type': 'page',
      'content': {
        'type': 'grid',
        'columns': _adaptiveColumns(deviceIds.length),
        'children': children,
      },
      'mcpRuntime': {
        'runtime': {
          'id': bundleId,
          'domain': 'appplayer.dashboard.auto',
          'version': '0.0.0',
        },
      },
    };

    return DashboardBundle(
      id: bundleId,
      mainLayout: mainLayout,
      slots: slots,
    );
  }

  int _adaptiveColumns(int count) {
    if (count <= 1) return 1;
    if (count <= 4) return 2;
    if (count <= 9) return 3;
    return 4;
  }

  DashboardBundle _parse(String id, Map<String, dynamic> json) {
    final mainLayout = (json['mainLayout'] is Map)
        ? Map<String, dynamic>.from(json['mainLayout'] as Map)
        : Map<String, dynamic>.from(json);

    final slotsRaw = json['slots'] as List<dynamic>? ?? const [];
    final slots = slotsRaw
        .map((e) =>
            SlotDefinition.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();

    final actionsRaw = json['commonActions'] as List<dynamic>? ?? const [];
    final commonActions = actionsRaw
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return DashboardBundle(
      id: id,
      mainLayout: mainLayout,
      slots: slots,
      commonActions: commonActions,
    );
  }
}
