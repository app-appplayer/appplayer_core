/// A bundle's `host.kb` records on this device follow the identity the host
/// gives the bundle, and leave with it. Nothing else's records do.
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:brain_kernel/brain_kernel.dart'
    show InMemoryKvStoragePort, KbExpectation, KvKbRecordStore;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/in_memory_server_storage.dart';

const String _bundleId = 'com.example.metadata_probe';

String _fixture() =>
    '${Directory.current.path}/test/fixtures/metadata_probe.mbd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late InMemoryKvStoragePort kv;
  late KvKbRecordStore records;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('appplayer-kb-local-');
    kv = InMemoryKvStoragePort();
    records = KvKbRecordStore(kv);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<AppPlayerCoreService> boot({
    String? Function(String bundleId)? appIdOf,
  }) async {
    final core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: tmp.path,
      kvStorage: kv,
      appIdOf: appIdOf,
    );
    addTearDown(core.dispose);
    return core;
  }

  Future<void> seed(String appId) => records.write(
        appId,
        'notes/a',
        <String, Object?>{'n': 1},
        expected: KbExpectation.unknown,
      );

  test('uninstall drops the bundle records on this device and no others',
      () async {
    final core = await boot();
    await core.installBundleFromDirectory(_fixture());
    await seed('bundle:$_bundleId');
    await seed('bundle:other.app');

    await core.uninstallBundle(_bundleId);

    expect(await records.list('bundle:$_bundleId', ''), isEmpty);
    expect(await records.list('bundle:other.app', ''), hasLength(1));
  });

  test('the app id the host gives a bundle is the one that is cleared',
      () async {
    final core = await boot(
      appIdOf: (bundleId) => bundleId == _bundleId ? 'listing:L1' : null,
    );
    await core.installBundleFromDirectory(_fixture());
    await seed('listing:L1');
    await seed('listing:L2');

    await core.uninstallBundle(_bundleId);

    expect(await records.list('listing:L1', ''), isEmpty);
    expect(await records.list('listing:L2', ''), hasLength(1),
        reason: 'another listing is not this bundle');
  });

  test('uninstall also drops the account copy and queue this device held',
      () async {
    final core = await boot();
    await core.installBundleFromDirectory(_fixture());
    // What a signed-in session leaves on the device: the last known account
    // copy and a write still waiting for the account.
    final appKey = Uri.encodeComponent('bundle:$_bundleId');
    await kv.set('app/$appKey/kbr/notes', <String, Object?>{'value': 1, 'version': 'v1'});
    await kv.set('app/$appKey/kbq/notes', <String, Object?>{'value': 2, 'deleted': false, 'seq': 1});

    await core.uninstallBundle(_bundleId);

    expect(await kv.keys(prefix: 'app/$appKey/'), isEmpty);
  });

  test('records in a file-backed store survive a new core on the same root',
      () async {
    final root = '${tmp.path}${Platform.pathSeparator}kv';
    final first = await boot();
    await first.dispose();

    final before = KvKbRecordStore(KvStoragePortAdapter(rootDir: root));
    await before.write('bundle:$_bundleId', 'notes/a', <String, Object?>{'n': 2},
        expected: KbExpectation.unknown);

    final core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: tmp.path,
      kvStorage: KvStoragePortAdapter(rootDir: root),
    );
    addTearDown(core.dispose);

    final after = KvKbRecordStore(KvStoragePortAdapter(rootDir: root));
    expect((await after.read('bundle:$_bundleId', 'notes/a'))?.value,
        <String, Object?>{'n': 2});
  });
}
