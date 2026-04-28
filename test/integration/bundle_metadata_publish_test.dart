/// End-to-end check of the install → open → metadata-sink chain for an
/// `.mbd/` bundle. Asserts that `RegistryMetadataSink` actually receives
/// the manifest-derived `AppMetadata` so the launcher tile can re-render
/// with the bundle's real name.
///
/// Reproduces the flow the Pro launcher's AppFormScreen exercises when a
/// user installs a bundle and the form fires its fire-and-forget
/// `openAppFromBundle` to publish metadata. The bundle fixture lives
/// under `test/fixtures/metadata_probe.mbd/` so this core test does not
/// reach upstream packages (Standard / Pro / X) for fixtures —
/// `os/core/appplayer` must be self-contained per the workspace
/// layering rule.
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/in_memory_server_storage.dart';

const String _bundleId = 'com.example.metadata_probe';
const String _bundleName = 'Metadata Probe';

class _Entry {
  _Entry({required this.id, this.name, this.iconUrl});
  final String id;
  final String? name;
  final String? iconUrl;
  _Entry copyWith({String? name, String? iconUrl}) =>
      _Entry(id: id, name: name ?? this.name, iconUrl: iconUrl ?? this.iconUrl);
}

class _InMemoryRegistry extends ValueNotifier<List<_Entry>>
    implements AppsRegistry<_Entry> {
  _InMemoryRegistry(super.initial);

  @override
  _Entry? byId(String appId) {
    for (final e in value) {
      if (e.id == appId) return e;
    }
    return null;
  }

  @override
  Future<void> add(_Entry app) async {
    final next = List<_Entry>.from(value);
    final i = next.indexWhere((e) => e.id == app.id);
    if (i >= 0) {
      next[i] = app;
    } else {
      next.add(app);
    }
    value = List.unmodifiable(next);
  }

  @override
  Future<void> update(_Entry app) async {
    final next = List<_Entry>.from(value);
    final i = next.indexWhere((e) => e.id == app.id);
    if (i < 0) return;
    next[i] = app;
    value = List.unmodifiable(next);
  }

  @override
  Future<void> remove(String appId) async {
    final next = value.where((e) => e.id != appId).toList();
    if (next.length == value.length) return;
    value = List.unmodifiable(next);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'installBundleFromDirectory + openAppFromBundle delivers manifest '
      'metadata to RegistryMetadataSink', () async {
    final mbdPath = _resolveMbd();
    expect(Directory(mbdPath).existsSync(), isTrue,
        reason: 'fixture missing: $mbdPath');

    final tmp = await Directory.systemTemp
        .createTemp('appplayer-bundle-meta-test-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    final registry = _InMemoryRegistry(const []);
    final sink = RegistryMetadataSink<_Entry>(
      registry: registry,
      merge: (e, m) => e.copyWith(
        name: m.name.trim().isNotEmpty ? m.name.trim() : null,
        iconUrl: m.iconUri,
      ),
    );

    final core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: tmp.path,
      appMetadataSink: sink,
    );
    addTearDown(() async => core.dispose());

    final installed = await core.installBundleFromDirectory(mbdPath);
    expect(installed.id, _bundleId);

    // Mirror the Pro AppFormScreen flow: register the AppConfig with
    // id == installed.id (1-to-1 mapping) so the sink can find it.
    await registry.add(_Entry(id: installed.id, name: installed.id));

    // Mirror _fetchBundleMetadata — open the bundle once to surface
    // metadata. Swallow runtime-engine initialization errors that can
    // happen in a test binding (the metadata publish runs BEFORE the
    // runtime init step inside _openFromBundleImpl, so the sink should
    // already have fired).
    try {
      final session =
          await core.openAppFromBundle(BundleInstalledRef(installed.id));
      await session.close();
    } catch (_) {
      // expected in test binding — see comment above
    }

    final entry = registry.byId(installed.id);
    expect(entry, isNotNull);
    expect(entry!.name, _bundleName,
        reason: 'metadata sink should overwrite id-as-name with manifest name');
  });
}

String _resolveMbd() {
  // Test runs from `os/core/appplayer/dart`. The fixture is a
  // self-contained `.mbd/` tree under `test/fixtures/`.
  final cwd = Directory.current.path;
  return '$cwd/test/fixtures/metadata_probe.mbd';
}
