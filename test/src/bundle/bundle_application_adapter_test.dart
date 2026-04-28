import 'dart:convert';
import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:appplayer_core/src/bundle/bundle_application_adapter.dart';
import 'package:appplayer_core/src/bundle/bundle_uri_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart'
    hide BundleLoadException, BundleLoader, MetricsPort;

/// Writes a minimal `.mbd/` tree under [tempRoot] and returns the
/// tagged [McpBundle]. The shape is whatever the server-side DSL
/// emits — pages are raw JSON copied into `ui/**.json` with no
/// translation.
Future<McpBundle> _writeBundle(
  Directory tempRoot, {
  required Map<String, dynamic> app,
  Map<String, Map<String, dynamic>> pages = const {},
  String? minRuntimeVersion,
  String entryPageId = 'main',
}) async {
  final mbd = await Directory('${tempRoot.path}/demo.mbd').create();
  await Directory('${mbd.path}/ui/pages').create(recursive: true);
  await File('${mbd.path}/ui/app.json')
      .writeAsString(jsonEncode(app));
  for (final e in pages.entries) {
    await File('${mbd.path}/ui/pages/${e.key}.json')
        .writeAsString(jsonEncode(e.value));
  }
  await File('${mbd.path}/manifest.json').writeAsString(jsonEncode({
    'schemaVersion': '1.0.0',
    'manifest': <String, dynamic>{
      'id': 'demo',
      'name': 'Demo',
      'version': '1.0.0',
      'schemaVersion': '1.0.0',
      'type': 'application',
      'entryPoint': 'ui.$entryPageId',
      if (minRuntimeVersion != null) 'minRuntimeVersion': minRuntimeVersion,
    },
  }));
  return McpBundleLoader.loadDirectory(mbd.path);
}

bool _adapt(Object? e, BundleAdaptReason reason) =>
    e is BundleAdaptException && e.reason == reason;

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('bundle_adapter_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  group('BundleApplicationAdapter (MOD-BUNDLE-004)', () {
    test('TC-BUNDLE-ADAPT-001: ui/app.json pass-through', () async {
      final bundle = await _writeBundle(tempRoot,
          app: <String, dynamic>{
            'type': 'application',
            'title': 'Demo',
            'initialRoute': '/',
            'routes': {'/': 'ui://pages/main'},
          },
          pages: {
            'main': {
              'type': 'page',
              'content': {'type': 'text', 'content': 'hi'},
            },
          });
      final adapter = BundleApplicationAdapter();
      final def = await adapter.adapt(
        bundle,
        const BundleEntryPoint(BundleEntryType.ui, 'main'),
        uriResolver: BundleUriResolver(),
      );
      expect(def.sourceKind, ApplicationSourceKind.localBundle);
      expect(def.appId, 'demo');
      expect(def.json['title'], 'Demo');
      expect(def.json['initialRoute'], '/');
      expect(def.json['routes'], {'/': 'ui://pages/main'});
    });

    test('TC-BUNDLE-ADAPT-002: missing ui/app.json rejected', () async {
      final mbd = await Directory('${tempRoot.path}/empty.mbd').create();
      await File('${mbd.path}/manifest.json').writeAsString(jsonEncode({
        'schemaVersion': '1.0.0',
        'manifest': {
          'id': 'demo',
          'name': 'Demo',
          'version': '1.0.0',
          'schemaVersion': '1.0.0',
          'type': 'application',
          'entryPoint': 'ui.main',
        },
      }));
      final bundle = await McpBundleLoader.loadDirectory(mbd.path);
      expect(
        () => BundleApplicationAdapter().adapt(
          bundle,
          const BundleEntryPoint(BundleEntryType.ui, 'main'),
          uriResolver: BundleUriResolver(),
        ),
        throwsA(predicate((e) =>
            _adapt(e, BundleAdaptReason.unsupportedEntryPoint))),
      );
    });

    test('TC-BUNDLE-ADAPT-003: minRuntimeVersion too high → throws',
        () async {
      final bundle = await _writeBundle(
        tempRoot,
        app: {'type': 'application'},
        minRuntimeVersion: '99.0',
      );
      expect(
        () => BundleApplicationAdapter().adapt(
          bundle,
          const BundleEntryPoint(BundleEntryType.ui, 'main'),
          uriResolver: BundleUriResolver(),
        ),
        throwsA(predicate((e) =>
            _adapt(e, BundleAdaptReason.incompatibleRuntimeVersion))),
      );
    });

    test('TC-BUNDLE-ADAPT-004: pageLoader resolves ui://pages/<id> from disk',
        () async {
      final bundle = await _writeBundle(tempRoot,
          app: {
            'type': 'application',
            'routes': {'/': 'ui://pages/main', '/settings': 'ui://pages/settings'},
          },
          pages: {
            'main': {'type': 'page', 'content': {'type': 'text'}},
            'settings': {
              'type': 'page',
              'route': '/settings',
              'content': {'type': 'text', 'content': 'settings body'},
            },
          });
      final adapter = BundleApplicationAdapter();
      final def = await adapter.adapt(
        bundle,
        const BundleEntryPoint(BundleEntryType.ui, 'main'),
        uriResolver: BundleUriResolver(),
      );
      final page = await def.pageLoader('ui://pages/settings');
      expect(page['type'], 'page');
      expect(page['route'], '/settings');
      expect(page['content'], isNotNull);
    });

    test('TC-BUNDLE-ADAPT-005: pageLoader throws for missing page file',
        () async {
      final bundle = await _writeBundle(tempRoot,
          app: {
            'type': 'application',
            'routes': {'/': 'ui://pages/main'},
          },
          pages: {
            'main': {'type': 'page', 'content': {'type': 'text'}},
          });
      final def = await BundleApplicationAdapter().adapt(
        bundle,
        const BundleEntryPoint(BundleEntryType.ui, 'main'),
        uriResolver: BundleUriResolver(),
      );
      await expectLater(
        def.pageLoader('ui://pages/nonexistent'),
        throwsA(isA<ResourceNotFoundException>()),
      );
    });
  });
}
