/// Opening a resolved target (platform spec 19 §9.4-§9.5).
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';

const String _bundleId = 'com.example.entry_probe';

EntryTargetRef _ref(EntryTargetKind kind, String ref, {String? route}) =>
    EntryTargetRef(kind: kind, ref: ref, route: route);

EntryContext _entry({String? route}) => EntryContext(
      route: route,
      issuer: const EntryIssuer(name: 'Fleet Co', verified: true),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppPlayerCoreService core;

  setUp(() async {
    final tmp = await Directory.systemTemp.createTemp('appplayer-opener-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: tmp.path,
    );
    addTearDown(() async => core.dispose());
    await core.installBundleFromDirectory(
      '${Directory.current.path}/test/fixtures/entry_probe.mbd',
    );
  });

  test('a bundle target opens on the page the entry named', () async {
    final opener = EntryOpener(core: core);
    final session = await opener.open(
      target: _ref(EntryTargetKind.bundle, _bundleId, route: '/contact'),
      entry: _entry(route: '/contact'),
    );
    expect(session.launchRouteMissing, isFalse);
    await session.close();
  });

  test('a server target registers once and reuses the registration', () async {
    const endpoint = 'https://fleet.example.test/mcp';
    final id = EntryOpener.serverIdFor(endpoint);
    final opener = EntryOpener(core: core);

    // Connecting fails offline; what is pinned here is the registration,
    // which happens before any dialling.
    try {
      await opener.open(
        target: _ref(EntryTargetKind.server, endpoint),
        entry: _entry(),
      );
    } catch (_) {}

    final saved = await core.getServer(id);
    expect(saved, isNotNull);
    expect(saved!.name, 'Fleet Co',
        reason: 'the issuer names the row a person will later see');
    expect(saved.transportConfig['url'], endpoint);

    final before = (await core.listServers()).length;
    try {
      await opener.open(
        target: _ref(EntryTargetKind.server, endpoint),
        entry: _entry(),
      );
    } catch (_) {}
    // Scanning the same medium twice must not accumulate a row per scan.
    expect((await core.listServers()).length, before);
  });

  test('a local node without a discoverer fails loudly', () async {
    final opener = EntryOpener(core: core);
    await expectLater(
      opener.open(
        target: _ref(EntryTargetKind.localServer, 'mdns:probe-01'),
        entry: _entry(),
      ),
      throwsA(isA<EntryOpenUnsupported>()),
    );
  });

  test('a local node uses the discoverer the tier wired', () async {
    var asked = '';
    final opener = EntryOpener(
      core: core,
      resolveLocalNode: (ref) async {
        asked = ref;
        return 'discovered-id';
      },
    );
    try {
      await opener.open(
        target: _ref(EntryTargetKind.localServer, 'mdns:probe-01'),
        entry: _entry(),
      );
    } catch (_) {}
    expect(asked, 'mdns:probe-01');
  });

  test('a listing is not something core can render', () async {
    // Acquisition is the marketplace's act; core has no path from a listing
    // id to a screen, and inventing one would blur install and run.
    final opener = EntryOpener(core: core);
    await expectLater(
      opener.open(
        target: _ref(EntryTargetKind.listing, 'listing-1'),
        entry: _entry(),
      ),
      throwsA(isA<EntryOpenUnsupported>()),
    );
  });

  test('an external target is host chrome, not a session', () async {
    final opener = EntryOpener(core: core);
    await expectLater(
      opener.open(
        target: _ref(EntryTargetKind.external, 'tel:+100000000'),
        entry: _entry(),
      ),
      throwsA(isA<EntryOpenUnsupported>()),
    );
  });
}
