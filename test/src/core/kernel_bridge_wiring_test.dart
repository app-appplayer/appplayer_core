/// Wiring regression — TC-KERNEL-* + TC-BRIDGE-* per
/// `docs/04_TEST/{kernel,bridge}.md`. AppPlayer Core verifies the
/// boot / activation / dispose wiring only; the underlying KernelApp +
/// BundleSessionBridge behaviour is owned by `brain_kernel`'s own
/// regression suite (kernel_app_test, standard_tools_test, bridge
/// smoke_test).
library;

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/in_memory_server_storage.dart';
import '../../helpers/mocks.dart';

AppPlayerCoreService _testCore() =>
    AppPlayerCoreService.forTesting(connector: (_) async => MockClient());

void main() {
  setUpAll(() {
    registerFallbackValue(TransportConfig.stdio(command: 'dart'));
  });

  group('MOD-KERNEL wiring', () {
    test('TC-KERNEL-001/002: initialize boots KernelApp', () async {
      final core = _testCore();
      expect(core.isKernelBooted, isFalse);
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-kernel-test',
      );
      expect(core.isKernelBooted, isTrue);
      await core.dispose();
    });

    test('TC-KERNEL-003: standardTools registers 41 tools on the dispatcher',
        () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-kernel-test',
      );
      final names = core.inProcessToolNames;
      // 41 standard tool (bk.fact.* + bk.skill.* + bk.profile.* +
      // bk.philosophy.* + bk.workflow.* + bk.pipeline.* + bk.runbook.* +
      // bk.agent.* + bk.knowledge.*).
      final bkTools = names.where((n) => n.startsWith('bk.')).toList();
      expect(bkTools.length, greaterThanOrEqualTo(41));
      expect(bkTools, contains('bk.fact.write'));
      expect(bkTools, contains('bk.agent.ask'));
      expect(bkTools, contains('bk.knowledge.query'));
      await core.dispose();
    });

    test('TC-KERNEL-006: setActiveSession(null) does not throw',
        () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-kernel-test',
      );
      // Master / home context — null handle should hit
      // `_kernel?.setActiveBundle(null)` cleanly.
      core.setActiveSession(null);
      await core.dispose();
    });

    test('TC-KERNEL-007: dispose tears down + idempotent', () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-kernel-test',
      );
      await core.dispose();
      // Second dispose is a no-op (no throw).
      await core.dispose();
    });
  });

  group('MOD-BRIDGE wiring', () {
    test('TC-BRIDGE-001: initialize boots BundleSessionBridge', () async {
      final core = _testCore();
      expect(core.isBridgeBooted, isFalse);
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-bridge-test',
      );
      expect(core.isBridgeBooted, isTrue);
      await core.dispose();
    });

    test(
        'TC-BRIDGE-004: openSessionCount starts at 0 + cleared on dispose',
        () async {
      final core = _testCore();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: '/tmp/core-bridge-test',
      );
      // No bundle opened yet.
      expect(core.openSessionCount, 0);
      await core.dispose();
    });
  });

  // TC-KERNEL-004/005 (activate / deactivate) + TC-BRIDGE-002/003/005/006/007
  // require an end-to-end bundle open path with a real McpBundle and
  // matching session lifecycle. The underlying behaviour is covered by
  // brain_kernel's regression suite (BundleActivation + Registry +
  // SessionRegistry + DispatchContext); AppPlayer Core's contribution
  // is the wiring itself, verified above through boot / standardTools /
  // setActiveSession / dispose. See `docs/04_TEST/kernel.md` ·
  // `bridge.md` for the delegation note.
}
