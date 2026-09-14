/// The production worker isolate, on this host's engine.
///
/// An evaluate on a runtime with no host bridge attached used to wait
/// forever: the worker got its reply port only from `attachHostBridge`. This
/// runs the real isolate — no bridge first — and a Promise that settles to an
/// object, which must come back as JSON.
library;

import 'dart:convert';

import 'package:appplayer_core/internals.dart';
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
}
