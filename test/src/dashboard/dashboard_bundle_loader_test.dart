import 'package:appplayer_core/src/connection/connection_manager.dart';
import 'package:appplayer_core/src/dashboard/dashboard_bundle.dart';
import 'package:appplayer_core/src/dashboard/dashboard_bundle_loader.dart';
import 'package:appplayer_core/src/exceptions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

class _FakeFetcher implements HttpBundleFetcher {
  _FakeFetcher(this.result);
  final Map<String, dynamic> result;

  @override
  Future<Map<String, dynamic>> fetch(String url) async => result;
}

void main() {
  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
  });

  group('DashboardBundleLoader (MOD-DASH-002)', () {
    test('TC-BUNDLE-001: inline', () async {
      final conn = ConnectionManager(
          connector: (_) async => throw StateError('unused'));
      final loader = DashboardBundleLoader(conn: conn);
      final ref = DashboardBundleRef(
        bundleId: 'b1',
        source: BundleSource.inline,
        inlineDefinition: const {
          'mainLayout': {'type': 'page'},
          'slots': [],
        },
      );
      final bundle = await loader.load(ref, connectedDevices: const []);
      expect(bundle.id, 'b1');
      expect(bundle.mainLayout['type'], 'page');
    });

    test('TC-BUNDLE-002: marketUrl via fetcher', () async {
      final conn = ConnectionManager(
          connector: (_) async => throw StateError('unused'));
      final loader = DashboardBundleLoader(
        conn: conn,
        httpFetcher: _FakeFetcher(const {
          'mainLayout': {'type': 'page'},
          'slots': <Map<String, dynamic>>[],
        }),
      );
      final bundle = await loader.load(
        DashboardBundleRef(
          bundleId: 'b2',
          source: BundleSource.marketUrl,
          url: 'https://example.com/b.json',
        ),
        connectedDevices: const [],
      );
      expect(bundle.id, 'b2');
    });

    test('TC-BUNDLE-003: marketUrl without fetcher throws', () async {
      final conn = ConnectionManager(
          connector: (_) async => throw StateError('unused'));
      final loader = DashboardBundleLoader(conn: conn);
      await expectLater(
        loader.load(
          DashboardBundleRef(
            bundleId: 'b3',
            source: BundleSource.marketUrl,
            url: 'https://x',
          ),
          connectedDevices: const [],
        ),
        throwsA(isA<DashboardBundleLoadException>()),
      );
    });

    test('TC-BUNDLE-005: aggregator server not connected', () async {
      final conn = ConnectionManager(
          connector: (_) async => throw StateError('unused'));
      final loader = DashboardBundleLoader(conn: conn);
      await expectLater(
        loader.load(
          DashboardBundleRef(
            bundleId: 'b4',
            source: BundleSource.aggregatorServer,
            aggregatorServerId: 'agg',
          ),
          connectedDevices: const [],
        ),
        throwsA(isA<DashboardBundleLoadException>()),
      );
    });

    test('TC-BUNDLE-006: synthesized with devices', () async {
      final conn = ConnectionManager(
          connector: (_) async => throw StateError('unused'));
      final loader = DashboardBundleLoader(conn: conn);
      final bundle = await loader.load(
        const DashboardBundleRef(
          bundleId: 'auto',
          source: BundleSource.synthesized,
        ),
        connectedDevices: const ['d1', 'd2', 'd3'],
      );
      expect(bundle.slots.length, 3);
      expect(bundle.slots.first.binding, isA<ExplicitBinding>());
      expect(bundle.mainLayout['content']['columns'], 2);
    });

    test('TC-BUNDLE-007: synthesized with no devices', () async {
      final conn = ConnectionManager(
          connector: (_) async => throw StateError('unused'));
      final loader = DashboardBundleLoader(conn: conn);
      final bundle = await loader.load(
        const DashboardBundleRef(bundleId: 'auto', source: BundleSource.synthesized),
        connectedDevices: const [],
      );
      expect(bundle.slots, isEmpty);
    });

    test('TC-BUNDLE-009: slots field missing tolerated', () async {
      final conn = ConnectionManager(
          connector: (_) async => throw StateError('unused'));
      final loader = DashboardBundleLoader(conn: conn);
      final bundle = await loader.load(
        const DashboardBundleRef(
          bundleId: 'b',
          source: BundleSource.inline,
          inlineDefinition: {
            'mainLayout': {'type': 'page'},
          },
        ),
        connectedDevices: const [],
      );
      expect(bundle.slots, isEmpty);
    });
  });
}
