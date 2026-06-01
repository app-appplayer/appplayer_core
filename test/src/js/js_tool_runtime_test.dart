import 'package:appplayer_core/internals.dart';
import 'package:flutter_test/flutter_test.dart';

/// JsToolRuntime — non-spawning surface tests are safe under
/// flutter_tester. The spawning path requires a flutter_js isolate
/// handshake that does not complete in the unit-test sandbox; the
/// production path (macOS / iOS / Android real run) is covered by
/// AppPlayer real-run verification.
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

  group(
    'JsToolRuntime — production isolate path',
    skip: 'flutter_js isolate handshake does not complete under '
        'flutter_tester. Production path covered by AppPlayer real-run verification.',
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
