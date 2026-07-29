/// Entry context reaching a real opened session (platform spec 19 §4.3,
/// MCP UI DSL §8.9).
///
/// The contract pinned here is "context survives the open": a scan that names
/// a page lands on that page, and what was scanned is still readable from the
/// document after it renders. Neither was possible before — the open path had
/// no parameter to carry them.
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:appplayer_core/internals.dart' show RuntimeManager;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show MCPUIRuntime;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';

const String _bundleId = 'com.example.entry_probe';

String _fixture() => '${Directory.current.path}/test/fixtures/entry_probe.mbd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppPlayerCoreService core;
  late RuntimeManager runtimes;

  setUp(() async {
    final tmp = await Directory.systemTemp.createTemp('appplayer-entry-test-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: tmp.path,
    );
    addTearDown(() async => core.dispose());

    await core.installBundleFromDirectory(_fixture());
    runtimes = core.runtimeManagerForInternals;
  });

  MCPUIRuntime openedRuntime() =>
      runtimes.getOrCreateRuntime(AppHandle.bundle(_bundleId));

  test('an entry route opens the app on that page', () async {
    final session = await core.openAppFromBundle(
      const BundleInstalledRef(_bundleId),
      entry: EntryContext(route: '/contact'),
    );
    expect(openedRuntime().engine.routeManager!.initialRoute, '/contact');
    await session.close();
  });

  test('no entry leaves the app on its own initial route', () async {
    final session =
        await core.openAppFromBundle(const BundleInstalledRef(_bundleId));
    expect(openedRuntime().engine.routeManager!.initialRoute, '/home');
    await session.close();
  });

  test('a route the app no longer declares falls back and reports the miss',
      () async {
    final session = await core.openAppFromBundle(
      const BundleInstalledRef(_bundleId),
      entry: EntryContext(route: '/retired'),
    );
    expect(openedRuntime().engine.routeManager!.initialRoute, '/home');
    // Spec 19 §9.6 puts the disclosure on the host, so the host needs a
    // surface to read — a log is not something a host can render.
    expect(session.launchRouteMissing, isTrue,
        reason: 'a stale binding must not look like a working one');
    await session.close();
  });

  test('an in-app open sets the route without inventing an entry', () async {
    final session = await core.openAppFromBundle(
      const BundleInstalledRef(_bundleId),
      launchRoute: '/contact',
    );
    expect(openedRuntime().engine.routeManager!.initialRoute, '/contact');
    // §8.9.1 reserves the entry tree for definitions reached from outside.
    expect(openedRuntime().entrySession.entry, isNull);
    expect(session.launchRouteMissing, isFalse);
    await session.close();
  });

  test('a launch route the app dropped is disclosed like an entry route',
      () async {
    final session = await core.openAppFromBundle(
      const BundleInstalledRef(_bundleId),
      launchRoute: '/retired',
    );
    expect(openedRuntime().engine.routeManager!.initialRoute, '/home');
    expect(session.launchRouteMissing, isTrue);
    await session.close();
  });

  test('an honoured route reports nothing to disclose', () async {
    final session = await core.openAppFromBundle(
      const BundleInstalledRef(_bundleId),
      entry: EntryContext(route: '/contact'),
    );
    expect(session.launchRouteMissing, isFalse);
    await session.close();
  });

  test('a session opened without an entry has nothing to disclose', () async {
    final session =
        await core.openAppFromBundle(const BundleInstalledRef(_bundleId));
    expect(session.launchRouteMissing, isFalse);
    await session.close();
  });

  test('entry params and issuer reach the document', () async {
    final session = await core.openAppFromBundle(
      const BundleInstalledRef(_bundleId),
      entry: EntryContext(
        route: '/contact',
        params: <String, dynamic>{'plate': 'AB-1234'},
        issuer: const EntryIssuer(name: 'Fleet Co', verified: true),
        grantScope: <String>['relay.notify'],
      ),
      identity: const IdentityContext(canPromote: true),
    );

    final entry = openedRuntime().entrySession.entry!;
    expect(entry.params['plate'], 'AB-1234');
    expect(entry.issuer!.name, 'Fleet Co');
    expect(entry.grantScope, contains('relay.notify'));
    expect(openedRuntime().entrySession.identity.state, IdentityState.guest);
    await session.close();
  });

  test('opening with no entry leaves the session context empty', () async {
    final session =
        await core.openAppFromBundle(const BundleInstalledRef(_bundleId));
    expect(openedRuntime().entrySession.entry, isNull);
    expect(openedRuntime().entrySession.hasHostSupport, isFalse);
    await session.close();
  });

  test('re-opening a live handle adopts the newer entry', () async {
    final first = await core.openAppFromBundle(
      const BundleInstalledRef(_bundleId),
      entry: EntryContext(params: <String, dynamic>{'plate': 'AB-1234'}),
    );
    final second = await core.openAppFromBundle(
      const BundleInstalledRef(_bundleId),
      entry: EntryContext(params: <String, dynamic>{'plate': 'ZZ-9999'}),
    );

    // The runtime is reused for a handle already open, so without an explicit
    // adopt the second scan would render the first scan's context — the same
    // medium scanned twice showing stale data.
    expect(openedRuntime().entrySession.entry!.params['plate'], 'ZZ-9999');
    await second.close();
    await first.close();
  });
}
