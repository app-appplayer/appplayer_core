/// A js tool's resolved value comes back as JSON text on every engine.
///
/// Runs the settle step against the engine this host has — JavaScriptCore on
/// macOS — so a regression that double-encodes there (JavaScriptCore already
/// stringifies what it settles) is caught here. The QuickJS side (Android,
/// Windows, Linux) is exercised on a device by the Pro integration test.
library;

import 'dart:convert';

import 'package:appplayer_core/src/js/js_tool_isolate_io.dart'
    show settleAsJson;
import 'package:flutter_js/extensions/handle_promises.dart';
import 'package:flutter_js/flutter_js.dart' as fjs;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late fjs.JavascriptRuntime rt;
  var id = 0;

  setUp(() {
    rt = fjs.getJavascriptRuntime(xhr: false)..enableHandlePromises();
    rt.evaluate('''
      async function objectTool(a) { return {count: a.n, at: "09:03"}; }
      async function arrayTool() { return [1, "two", {three: 3}]; }
      async function stringTool() { return "hi"; }
      async function numberTool() { return 42; }
      async function nothingTool() { }
      async function failingTool() { throw new Error("boom"); }
      function syncObjectTool() { return {sync: true}; }
      function syncFailingTool() { throw new Error("sync boom"); }
      async function cyclicTool() { var o = {}; o.self = o; return o; }
    ''');
  });

  tearDown(() => rt.dispose());

  Future<Object?> run(String call) async {
    final r = await settleAsJson(rt, call, id++);
    expect(r.isError, isFalse, reason: r.stringResult);
    return jsonDecode(r.stringResult);
  }

  test('an object comes back as the object', () async {
    expect(await run('objectTool({n: 2})'), {'count': 2, 'at': '09:03'});
  });

  test('an array comes back as the array', () async {
    expect(await run('arrayTool()'), [
      1,
      'two',
      {'three': 3}
    ]);
  });

  test('a string is a JSON string, not double-encoded', () async {
    expect(await run('stringTool()'), 'hi');
  });

  test('a number and undefined keep their JSON meaning', () async {
    expect(await run('numberTool()'), 42);
    expect(await run('nothingTool()'), isNull);
  });

  test('a synchronous return settles the same way', () async {
    expect(await run('syncObjectTool()'), {'sync': true});
  });

  test('a thrown error is an error, not a value', () async {
    final r = await settleAsJson(rt, 'failingTool()', id++);
    expect(r.isError, isTrue);
    expect(r.stringResult, contains('boom'));
    final s = await settleAsJson(rt, 'syncFailingTool()', id++);
    expect(s.isError, isTrue);
    expect(s.stringResult, contains('sync boom'));
  });

  test('an expression written as a statement with a trailing ; settles',
      () async {
    final r = await settleAsJson(
        rt,
        '''
      objectTool({n: 5})
        .then(function (v) { return {ok: true, count: v.count}; })
        .catch(function (e) { return {ok: false}; });
    ''',
        id++);
    expect(r.isError, isFalse, reason: r.stringResult);
    expect(jsonDecode(r.stringResult), {'ok': true, 'count': 5});
  });

  test('an expression ending in a // comment settles', () async {
    expect(await run('objectTool({n: 7}) // the last line is a comment'),
        {'count': 7, 'at': '09:03'});
  });

  test('code that is not an expression is an error with the engine message',
      () async {
    final r = await settleAsJson(rt, 'var x = 1; x', id++);
    expect(r.isError, isTrue);
    expect(r.stringResult, isNot(contains('settle produced no outcome')));
    expect(r.stringResult, isNotEmpty);
  });

  test('a value JSON cannot represent is an error', () async {
    final r = await settleAsJson(rt, 'cyclicTool()', id++);
    expect(r.isError, isTrue);
  });

  test('concurrent calls do not read each other\'s result', () async {
    final results = await Future.wait([
      settleAsJson(rt, 'objectTool({n: 1})', 1001),
      settleAsJson(rt, 'objectTool({n: 2})', 1002),
    ]);
    expect(jsonDecode(results[0].stringResult), {'count': 1, 'at': '09:03'});
    expect(jsonDecode(results[1].stringResult), {'count': 2, 'at': '09:03'});
  });
}
