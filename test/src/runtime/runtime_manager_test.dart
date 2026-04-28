import 'package:appplayer_core/appplayer_core.dart';
import 'package:appplayer_core/src/runtime/runtime_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RuntimeManager (MOD-RUNTIME-001)', () {
    const h1 = AppHandle.server('s1');
    const h2 = AppHandle.server('nope');
    const hA = AppHandle.server('a');
    const hB = AppHandle.bundle('b');

    test('TC-RTMGR-001/002: create then reuse', () {
      final m = RuntimeManager();
      final a = m.getOrCreateRuntime(h1);
      final b = m.getOrCreateRuntime(h1);
      expect(identical(a, b), isTrue);
      expect(m.hasRuntime(h1), isTrue);
    });

    test('TC-RTMGR-003: getRuntime/hasRuntime unknown handle', () {
      final m = RuntimeManager();
      expect(m.getRuntime(h2), isNull);
      expect(m.hasRuntime(h2), isFalse);
    });

    test('TC-RTMGR-004: removeRuntime', () async {
      final m = RuntimeManager();
      m.getOrCreateRuntime(h1);
      await m.removeRuntime(h1);
      expect(m.hasRuntime(h1), isFalse);
    });

    test('TC-RTMGR-005: removeRuntime unknown handle is no-op', () async {
      final m = RuntimeManager();
      await m.removeRuntime(h2);
      expect(m.runtimes.isEmpty, isTrue);
    });

    test('TC-RTMGR-006: removeAllRuntimes clears registry', () async {
      final m = RuntimeManager();
      m.getOrCreateRuntime(hA);
      m.getOrCreateRuntime(hB);
      await m.removeAllRuntimes();
      expect(m.runtimes.isEmpty, isTrue);
    });

    test('AppHandle: server and bundle with same key do not collide', () {
      final m = RuntimeManager();
      const serverHandle = AppHandle.server('shared-id');
      const bundleHandle = AppHandle.bundle('shared-id');
      final a = m.getOrCreateRuntime(serverHandle);
      final b = m.getOrCreateRuntime(bundleHandle);
      expect(identical(a, b), isFalse);
      expect(m.hasRuntime(serverHandle), isTrue);
      expect(m.hasRuntime(bundleHandle), isTrue);
    });
  });
}
