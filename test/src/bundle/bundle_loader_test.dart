import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:appplayer_core/src/bundle/bundle_loader_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _validBundleJson({
  String id = 'demo',
  String name = 'Demo',
  String version = '1.0.0',
  String schemaVersion = '1.0.0',
  String type = 'application',
  String? entryPoint,
}) {
  return <String, dynamic>{
    'schemaVersion': schemaVersion,
    'manifest': {
      'id': id,
      'name': name,
      'version': version,
      'schemaVersion': schemaVersion,
      'type': type,
      if (entryPoint != null) 'entryPoint': entryPoint,
    },
  };
}

class _StubFetcher implements BundleFetcher {
  _StubFetcher(this.payload);
  final Uint8List payload;
  Uri? lastUrl;

  @override
  Future<Uint8List> fetch(Uri url, {Map<String, String>? headers}) async {
    lastUrl = url;
    return payload;
  }
}

void main() {
  group('BundleLoaderAdapter (MOD-BUNDLE-001)', () {
    test('TC-BUNDLE-LOAD-001: inline ref success', () async {
      final loader = BundleLoaderAdapter();
      final bundle = await loader.load(BundleInlineRef(_validBundleJson()));
      expect(bundle.manifest.id, 'demo');
      expect(bundle.manifest.version, '1.0.0');
    });

    test('TC-BUNDLE-LOAD-002: unsupported schema version', () async {
      final loader = BundleLoaderAdapter();
      await expectLater(
        loader.load(BundleInlineRef(_validBundleJson(schemaVersion: '99.0'))),
        throwsA(predicate((e) =>
            e is BundleLoadException &&
            e.reason == BundleLoadReason.unsupportedSchema)),
      );
    });

    test('TC-BUNDLE-LOAD-003: manifest id empty', () async {
      final loader = BundleLoaderAdapter();
      await expectLater(
        loader.load(BundleInlineRef(_validBundleJson(id: ''))),
        throwsA(predicate((e) =>
            e is BundleLoadException &&
            e.reason == BundleLoadReason.invalidManifest)),
      );
    });

    test('TC-BUNDLE-LOAD-004: manifest name empty', () async {
      final loader = BundleLoaderAdapter();
      await expectLater(
        loader.load(BundleInlineRef(_validBundleJson(name: ''))),
        throwsA(predicate((e) =>
            e is BundleLoadException &&
            e.reason == BundleLoadReason.invalidManifest)),
      );
    });

    test('TC-BUNDLE-LOAD-005: remote ref uses injected fetcher', () async {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(_validBundleJson())));
      final fetcher = _StubFetcher(bytes);
      final loader = BundleLoaderAdapter(fetcher: fetcher);
      final bundle =
          await loader.load(BundleRemoteRef(Uri.parse('https://x/y.mcpb')));
      expect(bundle.manifest.id, 'demo');
      expect(fetcher.lastUrl.toString(), 'https://x/y.mcpb');
    });

    test('TC-BUNDLE-LOAD-006: remote ref without fetcher throws', () async {
      final loader = BundleLoaderAdapter();
      await expectLater(
        loader.load(BundleRemoteRef(Uri.parse('https://x/y.mcpb'))),
        throwsA(predicate((e) =>
            e is BundleLoadException &&
            e.reason == BundleLoadReason.fetchError)),
      );
    });

    test('TC-BUNDLE-LOAD-007: file ref rejected (host must pre-resolve)',
        () async {
      final loader = BundleLoaderAdapter();
      await expectLater(
        loader.load(const BundleFileRef('/tmp/bundle.mcpb')),
        throwsA(isA<BundleLoadException>()),
      );
    });

    test('TC-BUNDLE-LOAD-008: installed ref preserves directory', () async {
      final tempRoot =
          await Directory.systemTemp.createTemp('appplayer_installed_');
      addTearDown(() async {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });
      const bundleId = 'demo';
      final mbd = Directory('${tempRoot.path}/$bundleId')
        ..createSync(recursive: true);
      File('${mbd.path}/manifest.json')
          .writeAsStringSync(jsonEncode(_validBundleJson(id: bundleId)));

      final loader = BundleLoaderAdapter(installRoot: tempRoot.path);
      final bundle = await loader.load(const BundleInstalledRef(bundleId));

      expect(bundle.manifest.id, bundleId);
      expect(bundle.directory, isNotNull,
          reason: 'FR-BUNDLE-009: directory must survive the loader');
      // Compare in normalized form so a Windows backslash matches the
      // forward slash used by the test fixture.
      String norm(String s) => s.replaceAll('\\', '/');
      expect(norm(bundle.directory!), equals(norm(mbd.path)));
    });

    test('TC-BUNDLE-LOAD-009: installed ref missing id → notFound', () async {
      final tempRoot =
          await Directory.systemTemp.createTemp('appplayer_missing_');
      addTearDown(() async {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });

      final loader = BundleLoaderAdapter(installRoot: tempRoot.path);
      await expectLater(
        loader.load(const BundleInstalledRef('ghost')),
        throwsA(predicate((e) =>
            e is BundleLoadException &&
            e.reason == BundleLoadReason.notFound &&
            e.bundleId == 'ghost')),
      );
    });

    test('TC-BUNDLE-LOAD-010: installed ref without installRoot throws',
        () async {
      final loader = BundleLoaderAdapter();
      await expectLater(
        loader.load(const BundleInstalledRef('x')),
        throwsA(predicate((e) =>
            e is BundleLoadException &&
            e.reason == BundleLoadReason.unknown)),
      );
    });
  });
}
