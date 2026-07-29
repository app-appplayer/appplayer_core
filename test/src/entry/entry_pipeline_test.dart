/// Resolution rules (platform spec 19 §4.3).
///
/// Every rule here guards a failure that is invisible from the outside: a
/// substituted target, a replayed stale answer, or a guest sent at an account
/// wall all look like a working entry until someone is standing in front of
/// the thing they scanned.
library;

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubResolver implements EntryResolverPort {
  _StubResolver(this._answer);

  final EntryTarget _answer;
  int calls = 0;
  String? lastLocale;

  @override
  Future<EntryTarget> resolve(String code, {required String locale}) async {
    calls++;
    lastLocale = locale;
    return _answer;
  }
}

EntryTarget _ok({
  EntryTargetKind kind = EntryTargetKind.server,
  IdentityPolicy policy = IdentityPolicy.open,
  String? route,
  DateTime? validUntil,
  EntryStewardRef? steward,
  EntryGrant? grant,
}) {
  return EntryTarget(
    status: EntryStatus.ok,
    issuer: const EntryIssuer(name: 'Fleet Co', verified: true),
    target: EntryTargetRef(
      kind: kind,
      ref: 'https://example.test/mcp',
      route: route,
      params: const <String, dynamic>{'plate': 'AB-1234'},
    ),
    identityPolicy: policy,
    validUntil: validUntil,
    steward: steward,
    grant: grant,
  );
}

EntryPipeline _pipeline(
  EntryTarget answer, {
  Set<EntryTargetKind>? supported,
  DateTime? now,
  bool canIdentify = true,
}) {
  return EntryPipeline(
    resolver: _StubResolver(answer),
    canIdentify: canIdentify,
    supportedTargets: supported ??
        const <EntryTargetKind>{
          EntryTargetKind.server,
          EntryTargetKind.localServer,
          EntryTargetKind.bundle,
          EntryTargetKind.external,
        },
    clock: now == null ? null : () => now,
  );
}

void main() {
  const locale = 'ko-KR';

  group('§4.3 opening', () {
    test('an ok answer opens', () async {
      final d = await _pipeline(_ok()).decide('c', locale: locale);
      expect(d.canOpen, isTrue);
      expect(d.identityRequired, isFalse);
    });

    test('required policy tells the host to identify first', () async {
      final d = await _pipeline(_ok(policy: IdentityPolicy.required))
          .decide('c', locale: locale);
      expect(d.canOpen, isTrue);
      expect(d.identityRequired, isTrue);
    });

    test('the locale is sent so the issuer is not machine-translated',
        () async {
      final resolver = _StubResolver(_ok());
      final pipeline = EntryPipeline(
        resolver: resolver,
        supportedTargets: const <EntryTargetKind>{EntryTargetKind.server},
      );
      await pipeline.decide('c', locale: locale);
      expect(resolver.lastLocale, locale);
    });
  });

  group('§4.2 required needs a host that can identify', () {
    test('a host with no sign-in refuses rather than rendering a guest', () {
      // Answering a demand for identity by ignoring it produces a screen that
      // looks like it worked.
      return _pipeline(_ok(policy: IdentityPolicy.required), canIdentify: false)
          .decide('c', locale: locale)
          .then((d) {
        expect(d.canOpen, isFalse);
        expect(d.rejection, EntryRejection.identityUnavailable);
      });
    });

    test('open and optional still work on such a host', () async {
      for (final policy in <IdentityPolicy>[
        IdentityPolicy.open,
        IdentityPolicy.optional,
      ]) {
        final d = await _pipeline(_ok(policy: policy), canIdentify: false)
            .decide('c', locale: locale);
        expect(d.canOpen, isTrue, reason: 'the guest path needs no sign-in');
      }
    });
  });

  group('§4.3 rejections keep the issuer', () {
    test('a revoked answer is rejected and still names the issuer', () async {
      const revoked = EntryTarget(
        status: EntryStatus.revoked,
        issuer: EntryIssuer(name: 'Fleet Co', verified: true),
        reason: 'medium retired',
      );
      final d = await _pipeline(revoked).decide('c', locale: locale);
      expect(d.canOpen, isFalse);
      expect(d.rejection, EntryRejection.notOk);
      // The gate has to say who was asking, even on a failure.
      expect(d.target.issuer.name, 'Fleet Co');
      expect(d.target.reason, 'medium retired');
    });

    test('an ok answer with no target is not ok', () async {
      const headless = EntryTarget(
        status: EntryStatus.ok,
        issuer: EntryIssuer(name: 'Fleet Co'),
      );
      final d = await _pipeline(headless).decide('c', locale: locale);
      expect(d.canOpen, isFalse);
    });

    test('an answer past its validity is not replayed', () async {
      final d = await _pipeline(
        _ok(validUntil: DateTime.utc(2026, 1, 1)),
        now: DateTime.utc(2026, 1, 2),
      ).decide('c', locale: locale);
      expect(d.rejection, EntryRejection.stale,
          reason: 'custody may have changed since it was minted');
    });

    test('an answer inside its validity is used', () async {
      final d = await _pipeline(
        _ok(validUntil: DateTime.utc(2026, 1, 3)),
        now: DateTime.utc(2026, 1, 2),
      ).decide('c', locale: locale);
      expect(d.canOpen, isTrue);
    });

    test('a guest entry pointing at a listing is refused', () async {
      for (final policy in <IdentityPolicy>[
        IdentityPolicy.open,
        IdentityPolicy.optional,
      ]) {
        final d = await _pipeline(
          _ok(kind: EntryTargetKind.listing, policy: policy),
          supported: const <EntryTargetKind>{EntryTargetKind.listing},
        ).decide('c', locale: locale);
        expect(d.rejection, EntryRejection.accountWallForGuest,
            reason: 'a guest cannot pass the marketplace account wall');
      }
    });

    test('a guest entry pointing at a bundle is refused', () async {
      final d = await _pipeline(
        _ok(kind: EntryTargetKind.bundle, policy: IdentityPolicy.open),
      ).decide('c', locale: locale);
      expect(d.rejection, EntryRejection.accountWallForGuest);
    });

    test('the same listing under required identity opens', () async {
      final d = await _pipeline(
        _ok(kind: EntryTargetKind.listing, policy: IdentityPolicy.required),
        supported: const <EntryTargetKind>{EntryTargetKind.listing},
      ).decide('c', locale: locale);
      expect(d.canOpen, isTrue);
    });

    test('a local server is guest-reachable', () async {
      final d = await _pipeline(
        _ok(kind: EntryTargetKind.localServer, policy: IdentityPolicy.open),
      ).decide('c', locale: locale);
      expect(d.canOpen, isTrue,
          reason: 'a sticker on a machine needs no account');
    });

    test('a target kind this host cannot open is reported, not substituted',
        () async {
      final d = await _pipeline(
        _ok(kind: EntryTargetKind.localServer),
        supported: const <EntryTargetKind>{EntryTargetKind.server},
      ).decide('c', locale: locale);
      expect(d.rejection, EntryRejection.unsupportedTarget);
      // Nothing was swapped in: the answer still points where it pointed.
      expect(d.target.target!.kind, EntryTargetKind.localServer);
    });
  });

  group('§8.1 what reaches the document', () {
    test('route, params, issuer and grant scope cross; the token does not',
        () {
      final target = _ok(
        route: '/contact',
        grant: EntryGrant(
          token: 'secret-token',
          expiresAt: DateTime.utc(2026, 1, 1),
          scope: <String>['relay.notify'],
        ),
      );
      final ctx = target.toEntryContext();

      expect(ctx.route, '/contact');
      expect(ctx.params['plate'], 'AB-1234');
      expect(ctx.issuer!.name, 'Fleet Co');
      expect(ctx.grantScope, <String>['relay.notify']);
      // The document is told what it may offer, never what authorizes it.
      expect(ctx.toBindingMap().toString(), isNot(contains('secret-token')));
    });

    test('canSteward mirrors whether a management entry was granted', () {
      expect(_ok().toEntryContext().canSteward, isFalse);
      final withSteward = _ok(
        steward: const EntryStewardRef(
          kind: EntryTargetKind.server,
          ref: 'https://example.test/manage',
          route: '/manage',
        ),
      );
      expect(withSteward.toEntryContext().canSteward, isTrue);
    });
  });

  group('wire parsing defaults to the safe reading', () {
    test('an unknown status is not treated as ok', () {
      expect(EntryStatus.fromWire('somethingNew'), EntryStatus.denied);
      expect(EntryStatus.fromWire(null), EntryStatus.denied);
      expect(EntryStatus.fromWire('ok'), EntryStatus.ok);
    });

    test('an unparsed policy demands identity rather than assuming guest', () {
      // Guessing `open` would render a guest surface for an entry we failed
      // to understand; guessing `required` merely asks someone to sign in.
      expect(IdentityPolicy.fromWire('newPolicy'), IdentityPolicy.required);
      expect(IdentityPolicy.fromWire('optional'), IdentityPolicy.optional);
    });

    test('an unknown target kind is null rather than a guess', () {
      expect(EntryTargetKind.fromWire('hologram'), isNull);
      expect(EntryTargetKind.fromWire('localServer'),
          EntryTargetKind.localServer);
    });
  });

  group('§5.2 grant', () {
    test('expiry is exclusive of the instant it expires', () {
      final grant = EntryGrant(
        token: 't',
        expiresAt: DateTime.utc(2026, 1, 1, 12),
      );
      expect(grant.isExpiredAt(DateTime.utc(2026, 1, 1, 11, 59)), isFalse);
      expect(grant.isExpiredAt(DateTime.utc(2026, 1, 1, 12)), isTrue);
    });
  });
}
