/// The host may hand the core the fact graph the kernel writes to (platform
/// spec 30). Without one the core behaves as before.
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppPlayerCoreService> boot({FactGraphRuntime? factGraph}) async {
    final tmp = await Directory.systemTemp.createTemp('appplayer-fg-test-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: tmp.path,
      factGraph: factGraph,
    );
    addTearDown(core.dispose);
    return core;
  }

  Future<Object?> writeFact(AppPlayerCoreService core, String id) =>
      core.toolDispatcherForInternals.routerFor(null)('bk.fact.write', {
        'facts': [
          {
            'id': id,
            'type': 'note',
            'content': {'text': 'hello'},
          },
        ],
      });

  test('a fact graph handed to initialize is the one the kernel writes to',
      () async {
    final runtime = FactGraphRuntime.inMemory(defaultWorkspaceId: 'default');
    final core = await boot(factGraph: runtime);

    await writeFact(core, 'f-injected');
    expect(await runtime.facts.getFact('f-injected'), isNotNull);
  });

  test('without one the core boots and writes as before', () async {
    final core = await boot();
    expect(core.isKernelBooted, isTrue);
    await writeFact(core, 'f-default');
    final got = await core.toolDispatcherForInternals
        .routerFor(null)('bk.fact.get', {'id': 'f-default'});
    expect((got as Map)['ok'], isTrue);
  });
}
