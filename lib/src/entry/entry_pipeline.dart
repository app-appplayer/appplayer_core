/// Turns an acquired entry code into something the host can open
/// (platform spec 19 §4.3, §9).
///
/// Every acquisition path — an intercepted link, a scanner, a deferred entry
/// recovered after an install — produces the same code and MUST take the same
/// path afterwards (§9.2). That path is here, so the rules hold no matter
/// which door the code came through.
library;

import '../logging/logger.dart';
import 'entry_target.dart';

/// Answers an entry code. Implemented per deployment; the platform never
/// assumes where the registry lives, only that something dereferences codes
/// (§2.1 resolver).
abstract class EntryResolverPort {
  /// [locale] is sent so the issuer's own words come back translated — a host
  /// must never machine-translate an issuer's identity (§4.1.2).
  Future<EntryTarget> resolve(String code, {required String locale});
}

/// Why an entry could not be opened. Distinct from a resolver saying
/// `revoked`: these are decisions the host made about an otherwise valid
/// answer.
enum EntryRejection {
  /// The resolver did not say `ok`.
  notOk,

  /// Answer older than its own validity — must be re-resolved, never replayed.
  stale,

  /// A guest entry pointing at something account-gated (§4.3).
  accountWallForGuest,

  /// A target kind this host does not implement.
  unsupportedTarget,

  /// The entry demands an identified viewer and this host cannot identify
  /// anyone. Distinct from an unsupported target: the destination is fine,
  /// the viewer cannot be established.
  identityUnavailable,
}

/// What the host should do next.
class EntryDecision {
  const EntryDecision._({
    required this.target,
    required this.rejection,
    required this.identityRequired,
  });

  const EntryDecision.open(EntryTarget target,
      {required bool identityRequired})
      : this._(
          target: target,
          rejection: null,
          identityRequired: identityRequired,
        );

  const EntryDecision.reject(EntryTarget target, EntryRejection rejection)
      : this._(target: target, rejection: rejection, identityRequired: false);

  /// The resolver's answer, kept even on a rejection: the trust gate still
  /// names the issuer and says why (§9.7).
  final EntryTarget target;

  final EntryRejection? rejection;

  /// The host must identify the viewer before rendering (§4.2 `required`).
  final bool identityRequired;

  bool get canOpen => rejection == null;
}

/// Applies the resolution rules to a resolver's answer.
///
/// The rules it enforces are the ones whose violation is invisible: silently
/// substituting a target, replaying a stale answer, or sending a guest at an
/// account wall all *look* like working entries from the outside.
class EntryPipeline {
  EntryPipeline({
    required EntryResolverPort resolver,
    required Set<EntryTargetKind> supportedTargets,
    bool canIdentify = false,
    DateTime Function()? clock,
    Logger? logger,
  })  : _resolver = resolver,
        _supported = supportedTargets,
        _canIdentify = canIdentify,
        _clock = clock ?? DateTime.now,
        _logger = logger ?? NoopLogger();

  final EntryResolverPort _resolver;
  final Set<EntryTargetKind> _supported;

  /// Whether this host can establish who the viewer is at all. A build with
  /// no sign-in cannot serve a `required` entry, and rendering it as a guest
  /// would be exactly the partial surface §4.2 forbids.
  final bool _canIdentify;
  final DateTime Function() _clock;
  final Logger _logger;

  /// Target kinds a guest can actually reach. A guest cannot pass the
  /// marketplace account wall, so an `open` / `optional` entry that resolves
  /// to a listing is a dead end no matter how correct the rest of it is.
  static const Set<EntryTargetKind> guestReachable = <EntryTargetKind>{
    EntryTargetKind.server,
    EntryTargetKind.localServer,
    EntryTargetKind.external,
  };

  /// Resolve [code] and decide. Never falls back to another target: an entry
  /// that cannot be opened is reported, not substituted (§4.3).
  Future<EntryDecision> decide(String code, {required String locale}) async {
    final target = await _resolver.resolve(code, locale: locale);

    if (!target.isOk) {
      _logger.debug('entry.reject', {
        'status': target.status.wireName,
        'reason': target.reason,
      });
      return EntryDecision.reject(target, EntryRejection.notOk);
    }

    if (target.isStaleAt(_clock())) {
      // Custody may have changed since this was minted, so the answer is not
      // ours to reuse — the host re-resolves rather than replaying.
      return EntryDecision.reject(target, EntryRejection.stale);
    }

    final kind = target.target!.kind;
    final policy = target.identityPolicy;

    if (policy != IdentityPolicy.required && !guestReachable.contains(kind)) {
      _logger.warn('entry.guest.account_wall', {
        'kind': kind.wireName,
        'policy': policy.wireName,
      });
      return EntryDecision.reject(target, EntryRejection.accountWallForGuest);
    }

    if (!_supported.contains(kind)) {
      return EntryDecision.reject(target, EntryRejection.unsupportedTarget);
    }

    if (policy == IdentityPolicy.required && !_canIdentify) {
      // Rendering this as a guest would answer a demand for identity by
      // ignoring it — the failure looks like a working screen.
      return EntryDecision.reject(target, EntryRejection.identityUnavailable);
    }

    return EntryDecision.open(
      target,
      identityRequired: policy == IdentityPolicy.required,
    );
  }
}
