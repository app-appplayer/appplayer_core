import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/in_memory_server_storage.dart';
import '../../helpers/mocks.dart';

class _App implements HasAppHandle {
  _App({
    required this.handleKind,
    this.serverConfigId,
    this.bundleId,
    this.dashboardConnectionIds = const [],
    this.id = 'fallback-id',
  });
  @override
  final String handleKind;
  @override
  final String? serverConfigId;
  @override
  final String? bundleId;
  @override
  final List<String> dashboardConnectionIds;
  @override
  final String id;
}

AppPlayerCoreService _testCore() =>
    AppPlayerCoreService.forTesting(connector: (_) async => MockClient());

void main() {
  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
  });

  group('AppPlayerCoreServiceActivity (FR-CORE-ACTIVE-001)', () {
    late AppPlayerCoreService core;

    setUp(() async {
      core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/activity-test',
      );
    });

    tearDown(() async {
      await core.dispose();
    });

    test('handleFor server uses serverConfigId', () {
      final h = core.handleFor(_App(
        handleKind: 'server',
        serverConfigId: 's1',
      ));
      expect(h.source, AppSource.server);
      expect(h.key, 's1');
    });

    test('handleFor server falls back to id when serverConfigId is null',
        () {
      final h = core.handleFor(_App(handleKind: 'server', id: 'sId'));
      expect(h.key, 'sId');
    });

    test('handleFor bundle uses bundleId', () {
      final h = core.handleFor(_App(
        handleKind: 'bundle',
        bundleId: 'com.x',
      ));
      expect(h.source, AppSource.bundle);
      expect(h.key, 'com.x');
    });

    test('handleFor bundle falls back to id when bundleId is null', () {
      final h = core.handleFor(_App(handleKind: 'bundle', id: 'fb'));
      expect(h.source, AppSource.bundle);
      expect(h.key, 'fb');
    });

    test('handleFor dashboard returns synthetic server handle from id', () {
      final h = core.handleFor(_App(handleKind: 'dashboard', id: 'dash-1'));
      expect(h.source, AppSource.server);
      expect(h.key, 'dash-1');
    });

    test('handleFor unknown kind falls back to synthetic server handle', () {
      final h = core.handleFor(_App(handleKind: 'mystery', id: 'm'));
      expect(h.source, AppSource.server);
      expect(h.key, 'm');
    });

    test('isAppActive server → false when not connected', () {
      expect(
        core.isAppActive(_App(handleKind: 'server', serverConfigId: 's1')),
        isFalse,
      );
    });

    test('isAppActive bundle → false when not loaded', () {
      expect(
        core.isAppActive(_App(handleKind: 'bundle', bundleId: 'b1')),
        isFalse,
      );
    });

    test('isAppActive dashboard → false when no inner connection active',
        () {
      expect(
        core.isAppActive(_App(
          handleKind: 'dashboard',
          dashboardConnectionIds: ['x', 'y'],
        )),
        isFalse,
      );
    });

    test('isAppActive unknown kind → false', () {
      expect(
        core.isAppActive(_App(handleKind: 'mystery')),
        isFalse,
      );
    });
  });
}
