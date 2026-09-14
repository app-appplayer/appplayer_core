import 'package:appplayer_core/internals.dart';
import 'package:flutter_test/flutter_test.dart';

/// JsToolRuntime — the non-spawning surface, and the real worker isolate on
/// this host's engine.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JsEvalResult', () {
    test('constructor wires stringResult / isError', () {
      final r = JsEvalResult(stringResult: 'hi', isError: false);
      expect(r.stringResult, 'hi');
      expect(r.isError, isFalse);
    });

    test('isError true is round-tripped', () {
      final r = JsEvalResult(stringResult: 'boom', isError: true);
      expect(r.isError, isTrue);
    });
  });

  group('JsToolRuntime — non-spawn lifecycle', () {
    test('isDisposed is false on a fresh runtime', () {
      final rt = JsToolRuntime();
      expect(rt.isDisposed, isFalse);
    });

    test('dispose without ever spawning is a no-op', () async {
      final rt = JsToolRuntime();
      await rt.dispose();
      expect(rt.isDisposed, isTrue);
    });

    test('dispose is idempotent', () async {
      final rt = JsToolRuntime();
      await rt.dispose();
      await rt.dispose();
      expect(rt.isDisposed, isTrue);
    });

    test('evaluate on a disposed runtime throws StateError', () async {
      final rt = JsToolRuntime();
      await rt.dispose();
      expect(
        () => rt.evaluate('1+1'),
        throwsA(isA<StateError>()),
      );
    });

    test('evaluateAsync on a disposed runtime throws StateError',
        () async {
      final rt = JsToolRuntime();
      await rt.dispose();
      expect(
        () => rt.evaluateAsync('Promise.resolve(1)'),
        throwsA(isA<StateError>()),
      );
    });

    test('attachHostBridge on a disposed runtime throws StateError',
        () async {
      final rt = JsToolRuntime();
      await rt.dispose();
      expect(
        () => rt.attachHostBridge(
          atoms: const [],
          allowedAtoms: const [],
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  // Runs the real worker isolate. It was skipped as "the handshake does not
  // complete under flutter_tester"; the cause was the worker receiving its
  // reply port only from `attachHostBridge`, so a bridge-less evaluate never
  // answered. With the port handed over at spawn it runs here.
  group(
    'JsToolRuntime — production isolate path',
    () {
      test('evaluates a synchronous expression', () async {
        final rt = JsToolRuntime();
        final result = await rt.evaluate('1 + 2');
        expect(result.stringResult, '3');
        expect(result.isError, isFalse);
        await rt.dispose();
      });
    },
  );
}
