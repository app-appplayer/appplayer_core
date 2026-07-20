import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Consent prompt that always returns a fixed decision and counts calls, so
/// re-prompting behaviour can be asserted.
class _FixedPrompt implements ConsentPrompt {
  _FixedPrompt(this.decision);

  final ConsentDecision decision;
  int calls = 0;

  @override
  Future<ConsentDecision> request(
    AppHandle app,
    AppCapability capability,
    String reason,
  ) async {
    calls++;
    return decision;
  }
}

/// Permission port whose request outcome is configurable.
class _StubPermissions implements PlatformPermissionPort {
  _StubPermissions(this.outcome);

  final PermissionStatus outcome;
  int requests = 0;

  @override
  Future<PermissionStatus> status(PlatformPermission permission) async =>
      outcome;

  @override
  Future<PermissionStatus> request(PlatformPermission permission) async {
    requests++;
    return outcome;
  }

  @override
  Stream<void> get changes => const Stream.empty();
}

void main() {
  final app = const AppHandle.bundle('demo');

  group('CapabilityConsentManager', () {
    test('unknown → prompt → persist → reuse without re-prompting', () async {
      final prompt = _FixedPrompt(ConsentDecision.granted);
      final manager = CapabilityConsentManager(
        store: InMemoryConsentStore(),
        prompt: prompt,
      );

      // A capability with no OS backing (network) so only app-consent gates it.
      expect(await manager.ensure(app, AppCapability.network), isTrue);
      expect(prompt.calls, 1);

      // Second use reads the persisted grant — no second prompt.
      expect(await manager.ensure(app, AppCapability.network), isTrue);
      expect(prompt.calls, 1);
    });

    test('denied decision blocks the capability', () async {
      final manager = CapabilityConsentManager(
        store: InMemoryConsentStore(),
        prompt: _FixedPrompt(ConsentDecision.denied),
      );

      expect(await manager.ensure(app, AppCapability.network), isFalse);
    });

    test('two-tier gate: granted consent but denied OS permission blocks', () async {
      final permissions = _StubPermissions(PermissionStatus.denied);
      final manager = CapabilityConsentManager(
        store: InMemoryConsentStore(),
        prompt: _FixedPrompt(ConsentDecision.granted),
        permissions: permissions,
      );

      // location is OS-backed → consent alone is not enough.
      expect(await manager.ensure(app, AppCapability.location), isFalse);
      expect(permissions.requests, 1);
    });

    test('two-tier gate: granted consent + granted OS permission passes', () async {
      final permissions = _StubPermissions(PermissionStatus.granted);
      final manager = CapabilityConsentManager(
        store: InMemoryConsentStore(),
        prompt: _FixedPrompt(ConsentDecision.granted),
        permissions: permissions,
      );

      expect(await manager.ensure(app, AppCapability.location), isTrue);
      expect(permissions.requests, 1);
    });

    test('revoke clears the grant so the next use re-prompts', () async {
      final prompt = _FixedPrompt(ConsentDecision.granted);
      final manager = CapabilityConsentManager(
        store: InMemoryConsentStore(),
        prompt: prompt,
      );

      await manager.ensure(app, AppCapability.network);
      expect(prompt.calls, 1);

      await manager.revoke(app, AppCapability.network);
      await manager.ensure(app, AppCapability.network);
      expect(prompt.calls, 2, reason: 'revoked grant re-prompts');
    });

    test('grantsOf returns only granted capabilities', () async {
      final store = InMemoryConsentStore();
      await store.write(app, AppCapability.network, ConsentDecision.granted);
      await store.write(app, AppCapability.camera, ConsentDecision.denied);
      final manager = CapabilityConsentManager(
        store: store,
        prompt: _FixedPrompt(ConsentDecision.granted),
      );

      expect(await manager.grantsOf(app), {AppCapability.network});
    });

    test('osPermissionFor maps OS-backed capabilities and null otherwise', () {
      expect(osPermissionFor(AppCapability.notifications),
          PlatformPermission.notifications);
      expect(osPermissionFor(AppCapability.backgroundDelivery),
          PlatformPermission.backgroundExecution);
      expect(osPermissionFor(AppCapability.network), isNull);
      expect(osPermissionFor(AppCapability.fileRead), isNull);
    });
  });
}
