import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opening a `view`'s origin on demand (MCP UI DSL v1.4 Composition Profile).
///
/// A document names an origin; it never opens one. Registering a device does
/// not hold a connection open either — and holding one would be wrong, because
/// several boards serve a single peer at a time, so a permanent connection per
/// registered device has the last one to connect reset the others (measured on
/// the bench as `Connection reset by peer`).
///
/// So the host opens the origin when a `view` first needs it. This pins the
/// decision: the hook fires for an origin the kernel does not hold, carries the
/// id the document named, and a host that cannot open it leaves that one view
/// to its fallback rather than resolving against the wrong server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppPlayerCoreService> booted() async {
    final tmp = await Directory.systemTemp.createTemp('open_origin');
    final core = AppPlayerCoreService();
    await core.initialize(
      storage: _NoopServerStorage(),
      bundleInstallRoot: tmp.path,
    );
    addTearDown(() async {
      await core.dispose();
      await tmp.delete(recursive: true);
    });
    return core;
  }

  test('an unheld origin is opened before it is read', () async {
    final core = await booted();
    final asked = <String>[];
    core.useKernelDefinitionResolver(
      openOrigin: (id) async => asked.add(id),
    );

    // The open hook is a no-op here, so the read still fails — what matters is
    // that the host was asked, and asked for the right origin.
    await expectLater(
      core.definitionResolver!('ui://app', <String, dynamic>{
        'connection': 'esp32.node',
      }),
      throwsA(anything),
    );
    expect(asked, <String>['esp32.node']);
  });

  test('a host that cannot open the origin fails that view', () async {
    final core = await booted();
    core.useKernelDefinitionResolver(
      openOrigin: (id) async => throw StateError('no such device: $id'),
    );

    // The host's reason must survive. Swallowing it still fails the view — the
    // read cannot succeed either way — but the user is then told `no
    // connection: ghost` instead of why the device could not be reached, and
    // those call for different fixes.
    Object? caught;
    try {
      await core.definitionResolver!('ui://app', <String, dynamic>{
        'connection': 'ghost',
      });
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<StateError>());
    expect('$caught', contains('no such device: ghost'),
        reason: "the opener's reason is what tells the user what to do");
  });

  test('without the hook the resolver still fails closed', () async {
    final core = await booted();
    core.useKernelDefinitionResolver();

    // A host that wires no opener has not stopped claiming the profile — it
    // simply cannot reach unheld origins, and must say so rather than read the
    // ref against its own server (§7.10.1 rule 6).
    await expectLater(
      core.definitionResolver!('ui://app', <String, dynamic>{
        'connection': 'esp32.node',
      }),
      throwsA(anything),
    );
  });

  test('an unrecognised origin shape is refused before anything is opened',
      () async {
    final core = await booted();
    var opened = 0;
    core.useKernelDefinitionResolver(openOrigin: (_) async => opened++);

    await expectLater(
      core.definitionResolver!('ui://app', <String, dynamic>{'server': 'x'}),
      throwsA(isA<StateError>()),
    );
    expect(opened, 0, reason: 'guessing an origin is worse than failing');
  });
}

/// The composition path never touches saved servers — an origin lives in the
/// kernel client-host registry, not in ServerStorage.
class _NoopServerStorage implements ServerStorage {
  @override
  Future<List<ServerConfig>> getServers() async => const <ServerConfig>[];
  @override
  Future<ServerConfig?> getById(String id) async => null;
  @override
  Future<void> saveServer(ServerConfig server) async {}
  @override
  Future<void> deleteServer(String id) async {}
  @override
  Future<void> updateLastConnected(String id, DateTime at) async {}
  @override
  Future<void> toggleFavorite(String id) async {}
}
