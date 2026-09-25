/// The production worker isolate, on this host's engine.
///
/// An evaluate on a runtime with no host bridge attached used to wait
/// forever: the worker got its reply port only from `attachHostBridge`. This
/// runs the real isolate — no bridge first — and a Promise that settles to an
/// object, which must come back as JSON.
library;

import 'dart:convert';

import 'package:appplayer_core/internals.dart';
import 'package:appplayer_core/src/js/atoms/kb_atom.dart';
import 'package:brain_kernel/brain_kernel.dart'
    show BundleKbStore, InMemoryKvStoragePort, KbError, KvKbRecordStore;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('evaluate answers without a bridge, and an async object is JSON',
      () async {
    final rt = JsToolRuntime();
    try {
      final sum = await rt.evaluate('1 + 2');
      expect(sum.isError, isFalse, reason: sum.stringResult);
      expect(sum.stringResult, '3');

      await rt.evaluate('async function f() { return {count: 2}; }');
      final r = await rt.evaluateAsync('Promise.resolve(f())');
      expect(r.isError, isFalse, reason: r.stringResult);
      expect(jsonDecode(r.stringResult), {'count': 2});
    } finally {
      await rt.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  group('arguments JSON cannot carry are refused, not stored as null', () {
    late JsToolRuntime rt;
    late BundleKbStore store;
    late _RecordingAtom probe;

    setUp(() async {
      rt = JsToolRuntime();
      store = BundleKbStore(
        appId: 'bundle:works.notes',
        records: KvKbRecordStore(InMemoryKvStoragePort()),
      );
      probe = _RecordingAtom();
      await rt.attachHostBridge(
        atoms: [KbAtom(store), probe],
        allowedAtoms: const {'kb', 'probe'},
      );
    });

    tearDown(() => rt.dispose());

    Future<String> outcome(String call) async {
      final r = await rt.evaluateAsync(
        '$call.then(function (v) { return "ok:" + JSON.stringify(v); }, '
        'function (e) { return "err:" + e.message; })',
      );
      expect(r.isError, isFalse, reason: r.stringResult);
      return jsonDecode(r.stringResult) as String;
    }

    test('kb values: function, NaN, Infinity, nested function, cycle', () async {
      for (final value in [
        'function () {}',
        'NaN',
        'Infinity',
        '{a: 1, b: function () {}}',
        '[1, -Infinity]',
        '(function () { var o = {}; o.self = o; return o; })()',
      ]) {
        final got = await outcome('host.kb.put("doc", $value)');
        expect(got, startsWith('err:'), reason: value);
        expect(got, contains(KbError.invalidValue), reason: value);
      }
      expect(await store.get('doc'), isNull, reason: 'nothing was stored');
    });

    test('a kb key JSON cannot carry is an invalid key', () async {
      final got = await outcome('host.kb.get(function () {})');
      expect(got, contains(KbError.invalidKey));
    });

    test('undefined crosses as null and an undefined property is omitted', () async {
      expect(await outcome('host.kb.put("a", {x: undefined, y: 1})'), 'ok:{"ok":true}');
      expect(await store.get('a'), {'y': 1});
      expect(await outcome('host.kb.put("b", undefined)'), 'ok:{"ok":true}');
      expect(await store.get('b'), isNull);
      expect(await outcome('host.kb.put("c", {when: new Date(0)})'), 'ok:{"ok":true}');
      expect(await store.get('c'), {'when': '1970-01-01T00:00:00.000Z'});
    });

    test('an atom without its own policy is refused by name and never dispatched',
        () async {
      final got = await outcome('host.probe.echo("a", {cb: function () {}})');
      expect(got, 'err:Invalid argument(s): probe.echo: argument 1.cb is function, '
          'which JSON cannot carry');
      expect(probe.calls, isEmpty);

      expect(await outcome('host.probe.echo("a", [1, undefined])'), 'ok:["a",[1,null]]');
      expect(probe.calls.single, ['a', [1, null]]);
    });
  });
}

class _RecordingAtom extends AtomCategory {
  final List<List<Object?>> calls = [];

  @override
  String get key => 'probe';

  @override
  List<AtomVerb> get verbs => const [AtomVerb('echo')];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    calls.add(args);
    return args;
  }
}
