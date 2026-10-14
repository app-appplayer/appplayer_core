/// A host with no workspace still answers `host.member`: nobody in one, no
/// rights, no people (platform spec 24 §7.2). Without it a workspace app
/// opened there failed on its first call and drew nothing.
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';

const _id = 'com.example.member_probe';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a host that gives no member port answers outside a workspace',
      () async {
    final tmp = await Directory.systemTemp.createTemp('appplayer-member-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: tmp.path,
    );
    addTearDown(() async => core.dispose());
    await core.installBundleFromDirectory(
      '${Directory.current.path}/test/fixtures/member_probe.mbd',
    );
    final session =
        await core.openAppFromBundle(const BundleInstalledRef(_id));
    addTearDown(session.close);

    final answer = await core.toolDispatcherForInternals
        .routerFor(null, scope: _id)('member.probe', <String, dynamic>{});

    expect(answer, {'me': null, 'can': false, 'people': 0});
  });
}
