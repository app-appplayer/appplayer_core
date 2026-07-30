@TestOn('browser')
library;

import 'package:appplayer_core/internals.dart';
import 'package:flutter_test/flutter_test.dart';

/// A host atom that records what it was asked for, so the test can prove the
/// call actually crossed into the worker and came back — not that a Promise
/// merely resolved.
class _RecordingAtom implements AtomCategory {
  _RecordingAtom(this.key, this._handler);

  @override
  final String key;

  final Object? Function(String verb, List<Object?> args) _handler;

  final List<(String, List<Object?>)> calls = [];

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb('echo'),
    AtomVerb('boom'),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    calls.add((verb, args));
    return _handler(verb, args);
  }
}

void main() {
  group('JsToolRuntime on the web runs bundle JS in a worker', () {
    late JsToolRuntime isolate;

    setUp(() async {
      isolate = JsToolRuntime();
    });

    tearDown(() async {
      await isolate.dispose();
    });

    test('a fresh runtime is live', () {
      expect(isolate.isDisposed, isFalse);
    });

    test('evaluate returns the value', () async {
      final result = await isolate.evaluate('1 + 1');
      expect(result.isError, isFalse);
      expect(result.stringResult, '2');
    });

    test('a thrown error is reported, not swallowed', () async {
      final result = await isolate.evaluate('throw new Error("nope")');
      expect(result.isError, isTrue);
      expect(result.stringResult, contains('nope'));
    });

    test('the worker has no document — bundle JS cannot reach the page', () async {
      final result = await isolate.evaluate(
        'typeof document === "undefined" ? "absent" : "present"',
      );
      expect(result.isError, isFalse);
      expect(result.stringResult, 'absent');
    });

    test('host bridge round-trips a call from JS to the atom and back', () async {
      final atom = _RecordingAtom('probe', (verb, args) => {'saw': args});
      await isolate.attachHostBridge(
        atoms: [atom],
        allowedAtoms: {'probe'},
      );

      final result = await isolate.evaluateAsync(
        'host.probe.echo("a", 2).then(function(r) { return JSON.stringify(r); })',
      );

      expect(result.isError, isFalse);
      expect(result.stringResult, contains('"saw"'));
      expect(atom.calls.single.$1, 'echo');
      expect(atom.calls.single.$2, ['a', 2]);
    });

    test('an atom error becomes a rejected promise, not a dead runtime', () async {
      final atom = _RecordingAtom('probe', (verb, args) {
        throw StateError('atom refused');
      });
      await isolate.attachHostBridge(
        atoms: [atom],
        allowedAtoms: {'probe'},
      );

      final rejected = await isolate.evaluateAsync(
        'host.probe.boom().then('
        '  function() { return "resolved"; },'
        '  function(e) { return "rejected:" + e.message; })',
      );
      expect(rejected.stringResult, contains('rejected:'));
      expect(rejected.stringResult, contains('atom refused'));

      // The runtime survived the rejection.
      final after = await isolate.evaluate('40 + 2');
      expect(after.isError, isFalse);
      expect(after.stringResult, '42');
    });

    test('an atom outside allowedAtoms is not exposed', () async {
      final atom = _RecordingAtom('probe', (verb, args) => 'never');
      await isolate.attachHostBridge(
        atoms: [atom],
        allowedAtoms: const <String>{},
      );

      final result = await isolate.evaluate(
        'typeof host.probe === "undefined" ? "absent" : "present"',
      );
      expect(result.stringResult, 'absent');
      expect(atom.calls, isEmpty);
    });


    // The native branch cannot run its engine inside `flutter test`, so the
    // bootstrap it installs was never executed by any test — a malformed one
    // would only surface on a device. The bootstrap is shared, so evaluating
    // the native variant here in a real engine covers that shape too.
    test('the native bootstrap variant is valid JavaScript', () async {
      final nativeBootstrap = hostBridgeBootstrapJs(
        "function(p) { sendMessage('hostInvoke', p); }",
      );
      final result = await isolate.evaluate(
        'var sendMessage = function() {};\n'
        '$nativeBootstrap\n'
        'typeof globalThis.__hostCall === "function" ? "installed" : "missing"',
      );
      expect(result.isError, isFalse, reason: result.stringResult);
      expect(result.stringResult, 'installed');
    });

    test('dispose terminates the worker and refuses further calls', () async {
      await isolate.dispose();
      expect(isolate.isDisposed, isTrue);
      await expectLater(isolate.evaluate('1'), throwsStateError);
    });
  });
}
