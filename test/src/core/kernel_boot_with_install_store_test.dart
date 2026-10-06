import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' show MemoryBundleInstallStore;

import '../../helpers/in_memory_server_storage.dart';

/// A host that keeps installed bundles in storage (a browser) has no
/// directory: `bundleInstallRoot` is a placeholder. Boot handed it to the
/// kernel as the knowledge-bundle list's directory, the list's `File` read
/// threw (`Unsupported operation: _Namespace` on the web), and the core came
/// up without its kernel — no kernel tools, no bundle session bridge, no
/// activation — while the page looked fine.
///
/// The browser harness for `initialize` does not run (see
/// `test/integration/web_boot_test.dart`), so this test gives the VM the
/// browser's one relevant property instead: touching the filesystem throws.
void main() {
  Future<T> withoutFilesystem<T>(Future<T> Function() body) =>
      IOOverrides.runZoned(
        body,
        createFile: (path) =>
            throw UnsupportedError('no filesystem (File $path)'),
        createDirectory: (path) =>
            throw UnsupportedError('no filesystem (Directory $path)'),
      );

  test('the kernel boots for a host that keeps bundles in storage', () async {
    final core = AppPlayerCoreService();
    addTearDown(core.dispose);
    await withoutFilesystem(() => core.initialize(
          storage: InMemoryServerStorage(),
          bundleInstallRoot: '',
          bundleInstallStore: MemoryBundleInstallStore(),
        ));
    expect(core.isKernelBooted, isTrue);
    expect(core.inProcessToolNames, contains('bk.fact.write'));
  });
}
