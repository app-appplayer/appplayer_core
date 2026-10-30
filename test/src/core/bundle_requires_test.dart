/// A bundle that declares host tools it cannot run without is not opened when
/// this host lacks some of them (platform spec 06 §③) — all or nothing, and
/// the missing names are reported. `requires.builtinAtoms` is not a refusal:
/// bundles already in use declare categories this host has no atom for.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';

const _id = 'com.example.member_probe';

/// The fixture bundle copied with its `requires` replaced.
Future<String> _bundleRequiring(
  Directory tmp,
  String name,
  Map<String, dynamic>? requires,
) async {
  final src =
      Directory('${Directory.current.path}/test/fixtures/member_probe.mbd');
  final dst = Directory('${tmp.path}/$name.mbd')..createSync(recursive: true);
  for (final e in src.listSync(recursive: true)) {
    final rel = e.path.substring(src.path.length);
    if (e is Directory) {
      Directory('${dst.path}$rel').createSync(recursive: true);
    } else if (e is File) {
      File('${dst.path}$rel').createSync(recursive: true);
      e.copySync('${dst.path}$rel');
    }
  }
  final manifest = File('${dst.path}/manifest.json');
  final doc = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
  if (requires == null) {
    doc.remove('requires');
  } else {
    doc['requires'] = requires;
  }
  manifest.writeAsStringSync(jsonEncode(doc));
  return dst.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppPlayerCoreService core;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('appplayer-requires-');
    core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: '${tmp.path}/installed',
    );
  });

  tearDown(() async {
    await core.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<AppSession> open(String dir) async {
    await core.installBundleFromDirectory(dir);
    return core.openAppFromBundle(const BundleInstalledRef(_id));
  }

  test('a tool the host does not provide refuses the bundle, naming it',
      () async {
    final dir = await _bundleRequiring(tmp, 'missing', {
      'schemaVersion': '1.0.0',
      'builtinTools': ['io.read', 'form.render'],
    });
    await expectLater(
      open(dir),
      throwsA(
        isA<BundleRequirementsUnmetException>()
            .having((e) => e.bundleId, 'bundleId', _id)
            .having(
                (e) => e.missingTools, 'missing', ['io.read', 'form.render']),
      ),
    );
  });

  test('some provided and some not: the bundle is not opened with part',
      () async {
    core.registerCapabilityTools({
      'io.read': (args) async => {'ok': true},
    });
    final dir = await _bundleRequiring(tmp, 'partial', {
      'schemaVersion': '1.0.0',
      'builtinTools': ['io.read', 'form.render'],
    });
    await expectLater(
      open(dir),
      throwsA(
        isA<BundleRequirementsUnmetException>()
            .having((e) => e.missingTools, 'missing', ['form.render']),
      ),
    );
  });

  test('every declared tool provided: the bundle opens', () async {
    core.registerCapabilityTools({
      'io.read': (args) async => {'ok': true},
      'form.render': (args) async => {'ok': true},
    });
    final dir = await _bundleRequiring(tmp, 'provided', {
      'schemaVersion': '1.0.0',
      'builtinTools': ['io.read', 'form.render'],
    });
    final session = await open(dir);
    addTearDown(session.close);
  });

  test('a bundle that declares nothing opens as before', () async {
    final dir = await _bundleRequiring(tmp, 'none', null);
    final session = await open(dir);
    addTearDown(session.close);
  });

  test('an atom category this host has no atom for does not refuse the bundle',
      () async {
    final dir = await _bundleRequiring(tmp, 'atoms', {
      'schemaVersion': '1.0.0',
      'builtinAtoms': ['member', 'fs', 'ui', 'workspace'],
    });
    final session = await open(dir);
    addTearDown(session.close);
  });
}
