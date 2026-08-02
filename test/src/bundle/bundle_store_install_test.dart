/// Install → list → resolve → adapt, with host-provided storage instead
/// of a filesystem.
///
/// This is the chain AppPlayer Cloud runs in a browser. Each link was
/// separately anchored to a directory path, so the whole chain has to be
/// walked here — a link that still needed `dart:io` would pass its own
/// unit test and fail only in the browser.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:appplayer_core/src/bundle/bundle_application_adapter.dart';
import 'package:appplayer_core/src/bundle/bundle_installer_adapter.dart';
import 'package:appplayer_core/src/bundle/bundle_loader_adapter.dart';
import 'package:appplayer_core/src/bundle/bundle_uri_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;

/// Author the fixture as a `.mbd/` tree and pack it, so the archive
/// carries the integrity block the installer requires by default.
///
/// The filesystem is used to *build* the fixture, never as the install
/// destination — that is the memory store below, which is the point.
Future<Uint8List> _packSample(Directory tempRoot) async {
  final mbd = await Directory('${tempRoot.path}/demo.mbd').create();
  await Directory('${mbd.path}/ui/pages').create(recursive: true);
  await File('${mbd.path}/manifest.json').writeAsString(jsonEncode({
    'schemaVersion': '1.0.0',
    'manifest': <String, dynamic>{
      'id': 'demo',
      'name': 'Demo',
      'version': '1.0.0',
      'schemaVersion': '1.0.0',
      'type': 'application',
      'entryPoint': 'ui.main',
    },
  }));
  await File('${mbd.path}/ui/app.json').writeAsString(jsonEncode({
    'type': 'application',
    'title': 'Demo',
    'initialRoute': '/',
    'routes': {'/': 'ui://pages/main'},
  }));
  await File('${mbd.path}/ui/pages/main.json').writeAsString(jsonEncode({
    'type': 'page',
    'content': {'type': 'text', 'content': 'hi'},
  }));
  return McpBundlePacker.packDirectory(mbd.path);
}

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('bundle_store_install_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  test('install, list, resolve and adapt with no filesystem', () async {
    final store = MemoryBundleInstallStore();
    final installer = BundleInstallerAdapter.onStore(store: store);

    final installed = await installer.installBytes(await _packSample(tempRoot));
    expect(installed.id, 'demo');

    expect((await installer.list()).map((b) => b.id), ['demo']);

    final loader = BundleLoaderAdapter(installStore: store);
    final bundle = await loader.load(const BundleInstalledRef('demo'));
    expect(bundle.manifest.id, 'demo');
    expect(bundle.directory, isNull);

    final def = await BundleApplicationAdapter().adapt(
      bundle,
      const BundleEntryPoint(BundleEntryType.ui, 'main'),
      uriResolver: BundleUriResolver(),
    );
    expect(def.appId, 'demo');
    expect(def.json['title'], 'Demo');
  });

  test('an id that was never installed reports notFound, not a path error',
      () async {
    final loader = BundleLoaderAdapter(installStore: MemoryBundleInstallStore());
    await expectLater(
      loader.load(const BundleInstalledRef('missing')),
      throwsA(predicate((e) =>
          e is BundleLoadException && e.reason == BundleLoadReason.notFound)),
    );
  });

  test('neither root nor store still reports the wiring gap', () async {
    final loader = BundleLoaderAdapter();
    await expectLater(
      loader.load(const BundleInstalledRef('demo')),
      throwsA(predicate((e) =>
          e is BundleLoadException && e.reason == BundleLoadReason.unknown)),
    );
  });
}
