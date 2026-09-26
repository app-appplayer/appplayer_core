// Writes the notices for the native code an app takes on Apple platforms —
// Swift packages and CocoaPods — in the format
// `OpenSourceLicenses.registerBundled` reads (FR-LIC-004).
//
// The list is the app's: it is read from the app's own resolved packages and
// written into the app's own assets. This tool only knows where Xcode and
// CocoaPods keep things.
//
//   dart run <appplayer_core>/tool/licenses/apple_licenses.dart <app dir> [out]
//
// Run after the app has been built for iOS and macOS on this machine, so the
// packages are checked out. A package with no checkout or no license file
// stops the run — a notice is not guessed.
//
// Binaries a plugin brings as a Swift package artifact (not a pinned package)
// are traced too: each must be covered by `tool/licenses/apple_extra.json` in
// the app — `[{"covers": "artifact:<package>" | (none), "packages": [..],
// "license": ".."}]` — or the run stops. Such binaries often carry dozens of
// third-party components their own license file does not name.

import 'dart:convert';
import 'dart:io';

import 'notices.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: apple_licenses.dart <app dir> [out json]');
    exit(64);
  }
  // Resolved, so it compares equal to the path Xcode records for the workspace.
  final app = Directory(Directory(args[0]).resolveSymbolicLinksSync());
  final out = File(args.length > 1
      ? args[1]
      : '${app.path}/assets/licenses/apple.json');

  final byText = <String, Set<String>>{};
  void add(String name, String text) =>
      byText.putIfAbsent(text.trim(), () => {}).add(name);

  final extra = _extras(File('${app.path}/tool/licenses/apple_extra.json'));
  for (final e in extra['*'] ?? const <Map<String, dynamic>>[]) {
    add((e['packages'] as List).join(', '), e['license'] as String);
  }
  final usedExtras = <String>{};

  for (final platform in ['ios', 'macos']) {
    final workspace = Directory('${app.path}/$platform/Runner.xcworkspace');
    if (!workspace.existsSync()) continue;

    // Swift packages: the pins Xcode resolved, read from its checkouts.
    final resolved = File(
        '${workspace.path}/xcshareddata/swiftpm/Package.resolved');
    if (resolved.existsSync()) {
      final checkouts = [
        '${app.path}/build/$platform/SourcePackages/checkouts',
        ..._checkoutsFor(workspace),
        ..._allCheckouts(),
      ];
      final pins = (jsonDecode(resolved.readAsStringSync())['pins'] as List)
          .cast<Map<String, dynamic>>();
      for (final pin in pins) {
        final location = pin['location'] as String;
        final repo = location.split('/').last.replaceAll('.git', '');
        final version = (pin['state'] as Map)['version'] ??
            (pin['state'] as Map)['revision'];
        // The checkout at exactly the pinned revision — several apps keep
        // checkouts of the same package at different versions.
        final revision = (pin['state'] as Map)['revision'] as String?;
        final dir = checkouts
            .map((c) => Directory('$c/$repo'))
            .where((d) => d.existsSync() && _atRevision(d, revision))
            .firstOrNull;
        if (dir == null) {
          _stop('$platform: $repo is resolved but not checked out — build the '
              'app for $platform first');
        }
        final text = _licenseText(dir);
        if (text == null) _stop('$platform: $repo has no license file');
        add('$repo $version', text);
      }
    }

    // Binary artifacts: a folder per package. A pinned package is covered by
    // its checkout above; anything else was brought by a plugin.
    final pinned = resolved.existsSync()
        ? {
            for (final pin in (jsonDecode(resolved.readAsStringSync())['pins'] as List)
                .cast<Map<String, dynamic>>())
              (pin['identity'] as String).toLowerCase(),
          }
        : <String>{};
    final artifacts = Directory('${app.path}/build/$platform/SourcePackages/artifacts');
    if (artifacts.existsSync()) {
      for (final d in artifacts.listSync().whereType<Directory>()) {
        final folder = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (folder == 'extract' || pinned.contains(folder.toLowerCase())) continue;
        final package = folder.replaceFirst(RegExp(r'-\d.*$'), '');
        final covers = extra['artifact:$package'];
        if (covers == null) {
          _stop('$platform: $folder ships a binary no pinned package covers — '
              'add {"covers": "artifact:$package", ...} to tool/licenses/apple_extra.json');
        }
        if (usedExtras.add('artifact:$package')) {
          for (final e in covers) {
            if (e['license'] is String) {
              add('${(e['packages'] as List).join(', ')} (in $package)', e['license'] as String);
            }
          }
        }
      }
    }

    // CocoaPods: the acknowledgements it writes for the app's pods.
    final ack = File('${app.path}/$platform/Pods/Target Support Files/'
        'Pods-Runner/Pods-Runner-acknowledgements.plist');
    if (ack.existsSync()) {
      for (final (title, text) in _podNotices(ack)) {
        add(title, text);
      }
    }
  }

  final entries = noticesFrom(byText);
  final problem = noticeProblem(entries);
  if (problem != null) _stop('${out.path} would be refused at registration $problem');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(entries));
  final count = entries.fold<int>(0, (n, e) => n + (e['packages'] as List).length);
  stdout.writeln('$count packages, ${entries.length} notices → ${out.path}');
}

Never _stop(String why) {
  stderr.writeln(why);
  exit(2);
}

/// The DerivedData folders Xcode made for this workspace — there can be more
/// than one (a resolve and a build may each make their own), newest first.
List<String> _checkoutsFor(Directory workspace) {
  final home = Platform.environment['HOME'];
  final root = Directory('$home/Library/Developer/Xcode/DerivedData');
  if (!root.existsSync()) return const [];
  final found = <Directory>[];
  for (final d in root.listSync().whereType<Directory>()) {
    final info = File('${d.path}/info.plist');
    if (!info.existsSync()) continue;
    final r = Process.runSync('plutil', ['-extract', 'WorkspacePath', 'raw', info.path]);
    if ((r.stdout as String).trim() == workspace.path) {
      final checkouts = Directory('${d.path}/SourcePackages/checkouts');
      if (checkouts.existsSync()) found.add(checkouts);
    }
  }
  found.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  return [for (final d in found) d.path];
}

String? _licenseText(Directory dir) {
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) {
        final n = f.uri.pathSegments.last.toUpperCase();
        return n.startsWith('LICENSE') ||
            n.startsWith('LICENCE') ||
            n.startsWith('COPYING') ||
            n.startsWith('NOTICE');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) return null;
  return files.map((f) => f.readAsStringSync().trim()).join('\n\n');
}

/// `(title, text)` for every pod the acknowledgements name, read through
/// `plutil` so the tool needs no plist parser of its own.
List<(String, String)> _podNotices(File plist) {
  final r = Process.runSync(
      'plutil', ['-convert', 'json', '-o', '-', plist.path]);
  if (r.exitCode != 0) _stop('cannot read ${plist.path}');
  return podNoticesFrom(
      ((jsonDecode(r.stdout as String) as Map)['PreferenceSpecifiers'] as List)
          .cast<Map<String, dynamic>>());
}

/// Every checkouts folder in DerivedData, whatever workspace made it.
List<String> _allCheckouts() {
  final home = Platform.environment['HOME'];
  final root = Directory('$home/Library/Developer/Xcode/DerivedData');
  if (!root.existsSync()) return const [];
  return [
    for (final d in root.listSync().whereType<Directory>())
      if (Directory('${d.path}/SourcePackages/checkouts').existsSync())
        '${d.path}/SourcePackages/checkouts',
  ];
}

bool _atRevision(Directory dir, String? revision) {
  if (revision == null) return true;
  final r = Process.runSync('git', ['-C', dir.path, 'rev-parse', 'HEAD']);
  return r.exitCode == 0 && (r.stdout as String).trim() == revision;
}

Map<String, List<Map<String, dynamic>>> _extras(File f) {
  if (!f.existsSync()) return const {};
  final list = (jsonDecode(f.readAsStringSync()) as List).cast<Map<String, dynamic>>();
  final byCover = <String, List<Map<String, dynamic>>>{};
  for (final e in list) {
    final hasText = e['license'] is String && (e['license'] as String).trim().isNotEmpty;
    if (!hasText && e['coveredBy'] is! String) {
      _stop('${f.path}: an entry needs "license" (full text) or "coveredBy"');
    }
    byCover.putIfAbsent((e['covers'] as String?) ?? '*', () => []).add(e);
  }
  return byCover;
}
