// Writes the notices for the Maven modules an app ships on Android, in the
// format `OpenSourceLicenses.registerBundled` reads (FR-LIC-004).
//
// The list is the app's: it is resolved from the app's own release runtime
// classpath and written into the app's own assets.
//
//   dart run <appplayer_core>/tool/licenses/android_licenses.dart <app dir> [out]
//
// What a module says about itself decides its notice:
//   * notice files inside its archive are shown as they are (Google's
//     `third_party_licenses` are split into their components);
//   * a license its POM names is given the standard text — Apache-2.0 as
//     published, MIT/BSD with the holders the POM names;
//   * Google's own terms are named, since they are not open-source notices;
//   * `tool/licenses/android_extra.json` in the app adds what the build does
//     not say: `[{"covers": "group:name" | "lib:libx.so" | (none),
//     "packages": [..], "license": ".."}]` — or `"coveredBy": "where"` for a
//     library whose notice is already shown from elsewhere.
// Every native library in the release APK is then traced: to Flutter, to the
// module that brought it, or to an extra that covers it. One that is none of
// these stops the run — a binary nobody accounted for ships unannounced.
// Anything else unknown stops the run too — a notice is not guessed.
//
// The Flutter engine (`io.flutter`) is left out: Flutter ships its own notices.

import 'dart:convert';
import 'dart:io';

import 'notices.dart';

final _tools = File.fromUri(Platform.script).parent;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: android_licenses.dart <app dir> [out json]');
    exit(64);
  }
  final app = Directory(Directory(args[0]).resolveSymbolicLinksSync());
  final out = File(args.length > 1
      ? args[1]
      : '${app.path}/assets/licenses/android.json');
  final raw = File('${Directory.systemTemp.path}/appplayer_android_licenses.jsonl');
  final apk = File('${app.path}/build/app/outputs/flutter-apk/app-release.apk');
  if (!apk.existsSync()) {
    _stop('no release APK at ${apk.path} — run `flutter build apk --release` '
        'first; the native libraries are traced from what actually ships');
  }
  // An APK older than the lock file was built from other dependencies.
  final lock = File('${app.path}/pubspec.lock');
  if (lock.existsSync() && apk.lastModifiedSync().isBefore(lock.lastModifiedSync())) {
    _stop('the release APK predates pubspec.lock — rebuild it; a stale APK '
        'traces libraries the app no longer ships, or misses new ones');
  }

  final gradle = await Process.run(
    './gradlew',
    ['-q', '-I', '${_tools.path}/android_licenses.init.gradle',
      '-Dappplayer.licenses.out=${raw.path}', ':app:appplayerLicenses'],
    workingDirectory: '${app.path}/android',
  );
  if (gradle.exitCode != 0) {
    stderr.writeln(gradle.stderr);
    exit(1);
  }

  final extra = _extras(File('${app.path}/tool/licenses/android_extra.json'));
  final apache = File('${_tools.path}/texts/Apache-2.0.txt').readAsStringSync().trim();

  final byText = <String, Set<String>>{};
  void add(String name, String text) =>
      byText.putIfAbsent(text.trim(), () => {}).add(name);

  // Extras that name no module or library are always part of the notice.
  for (final e in extra['*'] ?? const <Map<String, dynamic>>[]) {
    add((e['packages'] as List).join(', '), e['license'] as String);
  }

  final broughtBy = <String, String>{}; // native library → module
  for (final line in raw.readAsLinesSync().where((l) => l.trim().isNotEmpty)) {
    final row = jsonDecode(line) as Map<String, dynamic>;
    final module = row['module'] as String;
    final parts = module.split(':');
    final coordinate = '${parts[0]}:${parts[1]}';
    for (final so in (row['natives'] as List? ?? const []).cast<String>()) {
      broughtBy[so] = module;
    }
    if (parts[0] == 'io.flutter') continue;

    final covered = extra[coordinate];
    if (covered != null) {
      for (final e in covered) {
        if (e['license'] is String) {
          add('${(e['packages'] as List).join(', ')} (in $module)', e['license'] as String);
        }
      }
      continue;
    }

    final notices = (row['notices'] as List).cast<Map<String, dynamic>>();
    final declared = (row['licenses'] as List).cast<Map<String, dynamic>>();
    final holders = (row['holders'] as List? ?? const []).cast<String>();
    var told = false;

    for (final (name, text) in _embedded(notices)) {
      add(name == null ? module : '$name (in $module)', text);
      told = true;
    }
    for (final l in declared) {
      final text = _standard(l['name'] as String, l['url'] as String,
          holders: holders, module: module, apache: apache);
      if (text == null) {
        if (told) continue; // its own files already carry the notice
        _stop('$module: "${l['name']}" (${l['url']}) is not a license this '
            'tool knows — cover it in tool/licenses/android_extra.json');
      }
      add(module, text);
      told = true;
    }
    if (!told) {
      _stop('$module declares no license and carries no notice — cover it in '
          'tool/licenses/android_extra.json');
    }
  }

  // Every native library that ships is accounted for.
  final listing = await Process.run('unzip', ['-Z1', apk.path]);
  final shipped = (listing.stdout as String)
      .split('\n')
      .where((l) => l.startsWith('lib/') && l.endsWith('.so'))
      .map((l) => l.split('/').last)
      .toSet();
  const fromFlutter = {'libflutter.so', 'libapp.so'};
  for (final so in shipped.toList()..sort()) {
    if (fromFlutter.contains(so) || broughtBy.containsKey(so)) continue;
    final covers = extra['lib:$so'];
    if (covers == null) {
      _stop('$so ships in the APK but no module brings it and no extra covers '
          'it — add {"covers": "lib:$so", ...} to tool/licenses/android_extra.json');
    }
    for (final e in covers) {
      if (e['license'] is String) {
        add((e['packages'] as List).join(', '), e['license'] as String);
      }
    }
  }

  final entries = noticesFrom(byText);
  final problem = noticeProblem(entries);
  if (problem != null) _stop('${out.path} would be refused at registration $problem');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(entries));
  final count = entries.fold<int>(0, (n, e) => n + (e['packages'] as List).length);
  stdout.writeln('$count entries, ${entries.length} notices → ${out.path}');
}

Never _stop(String why) {
  stderr.writeln(why);
  exit(2);
}

Map<String, List<Map<String, dynamic>>> _extras(File f) {
  if (!f.existsSync()) return const {};
  final list = (jsonDecode(f.readAsStringSync()) as List).cast<Map<String, dynamic>>();
  final byCoordinate = <String, List<Map<String, dynamic>>>{};
  for (final e in list) {
    final hasText = e['license'] is String && (e['license'] as String).trim().isNotEmpty;
    if (!hasText && e['coveredBy'] is! String) {
      _stop('${f.path}: an entry needs "license" (full text) or "coveredBy"');
    }
    byCoordinate.putIfAbsent((e['covers'] as String?) ?? '*', () => []).add(e);
  }
  return byCoordinate;
}

/// The notices a module carries, as `(component or null, text)`. Google's
/// `third_party_licenses.json` indexes byte ranges of the `.txt` beside it.
List<(String?, String)> _embedded(List<Map<String, dynamic>> notices) {
  String? textOf(String suffix) => notices
      .where((n) => (n['path'] as String).toLowerCase().endsWith(suffix))
      .map((n) => n['text'] as String)
      .firstOrNull;
  final index = textOf('third_party_licenses.json');
  final body = textOf('third_party_licenses.txt');
  final found = <(String?, String)>[];
  if (index != null && body != null) {
    final bytes = utf8.encode(body);
    final map = (jsonDecode(index) as Map).cast<String, dynamic>();
    for (final e in map.entries) {
      final at = (e.value as Map)['start'] as int;
      final length = (e.value as Map)['length'] as int;
      if (at + length > bytes.length) continue;
      found.add((e.key, utf8.decode(bytes.sublist(at, at + length))));
    }
  }
  for (final n in notices) {
    final path = (n['path'] as String).toLowerCase();
    if (path.contains('third_party_licenses')) continue;
    final text = (n['text'] as String).trim();
    if (text.isNotEmpty) found.add((null, text));
  }
  return found;
}

String? _standard(String name, String url,
    {required List<String> holders, required String module, required String apache}) {
  final n = '${name.toLowerCase()} ${url.toLowerCase()}';
  final who = holders.isEmpty ? 'the authors of $module' : holders.join(', ');
  if (n.contains('apache')) return apache;
  if (n.contains('bouncy castle')) {
    return _mit.replaceFirst(
        '{holders}', 'The Legion of the Bouncy Castle Inc. (https://www.bouncycastle.org)');
  }
  if (RegExp(r'\bmit\b').hasMatch(n)) return _mit.replaceFirst('{holders}', who);
  if (n.contains('3-clause') || n.contains('bsd-3') || n.contains('new bsd')) {
    return _bsd3.replaceFirst('{holders}', who);
  }
  if (n.contains('simplified bsd') || n.contains('bsd-2') || n.contains('2-clause')) {
    return _bsd2.replaceFirst('{holders}', who);
  }
  // Google's own terms are terms, not an open-source notice: named and linked.
  if (n.contains('android software development kit') ||
      n.contains('android sdk license') ||
      n.contains('terms of service')) {
    return '$name\n$url';
  }
  return null;
}

const _mit = '''MIT License

Copyright (c) {holders}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';

const _bsd2 = '''BSD 2-Clause License

Copyright (c) {holders}

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.''';

const _bsd3 = '''BSD 3-Clause License

Copyright (c) {holders}

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.''';
