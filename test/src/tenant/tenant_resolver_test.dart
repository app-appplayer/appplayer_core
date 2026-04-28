import 'package:appplayer_core/src/exceptions.dart';
import 'package:appplayer_core/src/tenant/tenant_context.dart';
import 'package:appplayer_core/src/tenant/tenant_resolver.dart';
import 'package:appplayer_core/src/tenant/tenant_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSource implements TenantSource {
  _FakeSource(this._map);
  final Map<String, TenantContext?> _map;
  @override
  Future<TenantContext?> resolve(String appCode) async => _map[appCode];
}

void main() {
  group('TenantResolver (MOD-TENANT-001)', () {
    TenantContext _ctx() => const TenantContext(
          appCode: 'A',
          allowedServerIds: {'s1'},
          allowedBundleIds: {'b1'},
        );

    test('TC-TENANT-001: apply sets current', () async {
      final r = TenantResolver(source: _FakeSource({'A': _ctx()}));
      final ctx = await r.apply('A');
      expect(r.current, same(ctx));
      expect(r.isActive, isTrue);
    });

    test('TC-TENANT-002: source missing throws', () async {
      final r = TenantResolver();
      await expectLater(
        r.apply('A'),
        throwsA(isA<TenantResolveException>()),
      );
    });

    test('TC-TENANT-003: unknown app code throws', () async {
      final r = TenantResolver(source: _FakeSource({'A': null}));
      await expectLater(
        r.apply('A'),
        throwsA(isA<TenantResolveException>()),
      );
    });

    test('TC-TENANT-004: clear', () async {
      final r = TenantResolver(source: _FakeSource({'A': _ctx()}));
      await r.apply('A');
      r.clear();
      expect(r.isActive, isFalse);
    });

    test('TC-TENANT-005: assertAllowedServer allow/deny', () async {
      final r = TenantResolver(source: _FakeSource({'A': _ctx()}));
      await r.apply('A');
      r.assertAllowedServer('s1');
      expect(
        () => r.assertAllowedServer('s2'),
        throwsA(isA<TenantAccessDeniedException>()),
      );
    });

    test('TC-TENANT-007: open mode (no tenant) — allow all', () {
      final r = TenantResolver();
      r.assertAllowedServer('anything');
      r.assertAllowedBundle('anything');
    });

    test('TC-TENANT-008: assertAllowedBundle allow/deny', () async {
      final r = TenantResolver(source: _FakeSource({'A': _ctx()}));
      await r.apply('A');
      r.assertAllowedBundle('b1');
      expect(
        () => r.assertAllowedBundle('b2'),
        throwsA(isA<TenantAccessDeniedException>()),
      );
    });
  });
}
