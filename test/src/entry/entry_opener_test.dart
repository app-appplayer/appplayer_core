/// Opening a resolved target (platform spec 19 §9.4-§9.5).
library;

import 'dart:async';
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

  test('a bundle this device does not have is reported as not installed',
      () async {
    final opener = EntryOpener(core: core);
    await expectLater(
      opener.open(
        target: _ref(EntryTargetKind.bundle, 'com.example.not_here'),
        entry: _entry(),
      ),
      throwsA(isA<EntryTargetNotInstalled>()
          .having((e) => e.ref, 'ref', 'com.example.not_here')),
    );
  });

  test('a server target registers once, on the key the transport reads',
      () async {
    // A closed loopback port: the dial must refuse at once rather than resolve
    // and retry, because what is pinned here is the registration and a test
    // that waits on the network is a test that reports the network.
    const endpoint = 'http://127.0.0.1:1/mcp';
    final id = EntryOpener.serverIdFor(endpoint);
    final opener = EntryOpener(core: core);

    // The transport reports a failed dial by adding an error to a broadcast
    // stream, and that does not arrive at an `await`. A plain try/catch here
    // lets it through to the framework as an unhandled async error, so the
    // zone has to be the one that swallows it.
    Future<void> scan() {
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            await opener
                .open(
                  target: _ref(EntryTargetKind.server, endpoint),
                  entry: _entry(),
                )
                .timeout(const Duration(seconds: 5));
          } catch (_) {
          } finally {
            if (!done.isCompleted) done.complete();
          }
        },
        (_, __) {
          if (!done.isCompleted) done.complete();
        },
      );
      return done.future;
    }

    await scan();

    final saved = await core.getServer(id);
    expect(saved, isNotNull);
    expect(saved!.name, 'Fleet Co',
        reason: 'the issuer names the row a person will later see');
    // `baseUrl` is what the transport factory reads. This assertion used to
    // name `url`, which storage accepts and the factory rejects — so every
    // scanned endpoint registered cleanly and then refused to dial, and the
    // test that was supposed to catch it pinned the wrong key instead.
    expect(saved.transportConfig['baseUrl'], endpoint);

    final before = (await core.listServers()).length;
    await scan();
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
