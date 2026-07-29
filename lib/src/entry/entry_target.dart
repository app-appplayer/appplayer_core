/// What a resolver answers for an entry code (platform spec 19 §4.1).
///
/// This is the **entry-host side** of the standard: what to open, where inside
/// it, and with how much identity. Its document-side counterpart is
/// `EntryContext`, which is what the opened definition gets to read — the two
/// are deliberately different shapes, because most of what a resolver says is
/// for the host to act on and never reaches the document.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show EntryContext, EntryIssuer, EntryNotice;

/// Whether an entry may be acted on at all (§4.1).
enum EntryStatus {
  ok,
  revoked,
  expired,
  denied;

  String get wireName => name;

  static EntryStatus fromWire(String? value) {
    for (final s in EntryStatus.values) {
      if (s.wireName == value) return s;
    }
    // An unknown status is not an ok status. Reading it permissively is how a
    // revoked medium would render.
    return EntryStatus.denied;
  }
}

/// How much identity an entry asks for (§4.2).
enum IdentityPolicy {
  /// Renders as guest; the host never prompts.
  open,

  /// Renders as guest and may offer promotion. The load-bearing value.
  optional,

  /// Identification precedes rendering.
  required;

  String get wireName => name;

  static IdentityPolicy fromWire(String? value) {
    for (final p in IdentityPolicy.values) {
      if (p.wireName == value) return p;
    }
    // Unknown policy is treated as the most demanding one: rendering a guest
    // surface for an entry whose policy we failed to parse is the failure
    // that leaks, and the opposite merely asks someone to sign in.
    return IdentityPolicy.required;
  }
}

/// What kind of thing an entry opens (§4.1).
enum EntryTargetKind {
  /// A served MCP endpoint.
  server,

  /// A node discovered on this network rather than dereferenced (§4.1.1).
  localServer,

  /// An installed bundle.
  bundle,

  /// A marketplace listing — account-gated, so never for guests (§4.3).
  listing,

  /// `tel:` / `mailto:` / an https page.
  external;

  String get wireName => name;

  static EntryTargetKind? fromWire(String? value) {
    for (final k in EntryTargetKind.values) {
      if (k.wireName == value) return k;
    }
    return null;
  }
}

/// Where an entry points, and where inside it.
@immutable
class EntryTargetRef {
  EntryTargetRef({
    required this.kind,
    required this.ref,
    this.route,
    Map<String, dynamic>? params,
  }) : params = Map<String, dynamic>.unmodifiable(
          params ?? const <String, dynamic>{},
        );

  final EntryTargetKind kind;
  final String ref;
  final String? route;
  final Map<String, dynamic> params;
}

/// The scan's own authority (§5.2). Short-lived, single-medium, scope-limited,
/// and never persisted — it is not an asset credential.
@immutable
class EntryGrant {
  EntryGrant({
    required this.token,
    required this.expiresAt,
    List<String>? scope,
  }) : scope = List<String>.unmodifiable(scope ?? const <String>[]);

  final String token;
  final DateTime expiresAt;
  final List<String> scope;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);
}

/// The management entry for the medium, present only when the resolved
/// principal may use it (§6.5).
@immutable
class EntryStewardRef {
  const EntryStewardRef({
    required this.kind,
    required this.ref,
    this.route,
  });

  final EntryTargetKind kind;
  final String ref;
  final String? route;
}

/// A resolver's complete answer.
@immutable
class EntryTarget {
  const EntryTarget({
    required this.status,
    required this.issuer,
    this.target,
    this.identityPolicy = IdentityPolicy.required,
    this.grant,
    this.steward,
    this.notice,
    this.reason,
    this.validUntil,
  });

  final EntryStatus status;
  final EntryIssuer issuer;

  /// Absent when [status] is not [EntryStatus.ok].
  final EntryTargetRef? target;

  final IdentityPolicy identityPolicy;
  final EntryGrant? grant;
  final EntryStewardRef? steward;
  final EntryNotice? notice;

  /// Why, when this is not an `ok`.
  final String? reason;

  /// After this the answer must be re-resolved rather than replayed (§4.3) —
  /// custody may have changed since.
  final DateTime? validUntil;

  bool get isOk => status == EntryStatus.ok && target != null;

  bool isStaleAt(DateTime now) {
    final until = validUntil;
    return until != null && !now.isBefore(until);
  }

  /// The slice of this answer the opened definition may read (§8.1).
  ///
  /// Owner and holder never appear, and neither does the grant token: the
  /// document is told what it may *offer*, not what authorizes it.
  EntryContext toEntryContext() {
    return EntryContext(
      route: target?.route,
      params: target?.params,
      issuer: issuer,
      grantScope: grant?.scope,
      canSteward: steward != null,
      notice: notice,
    );
  }
}

/// Wire parsing for a resolver's answer.
///
/// The shape is the field list of §4.1 as JSON. Parsing is deliberately
/// defensive at every field a permissive reading would make dangerous — see
/// the `fromWire` helpers above.
extension EntryTargetCodec on EntryTarget {
  /// Parse a resolver response.
  ///
  /// A malformed or unrecognised answer becomes a `denied` target rather than
  /// an exception: the host has to render a trust gate either way, and an
  /// exception at this seam would surface as a crash on a scan.
  static EntryTarget fromJson(Map<String, dynamic> json) {
    final issuerJson = json['issuer'];
    final issuer = issuerJson is Map<String, dynamic>
        ? EntryIssuer(
            name: issuerJson['name'] as String? ?? '',
            verified: issuerJson['verified'] as bool? ?? false,
          )
        : const EntryIssuer(name: '');

    final status = EntryStatus.fromWire(json['status'] as String?);
    final targetJson = json['target'];
    EntryTargetRef? target;
    if (targetJson is Map<String, dynamic>) {
      final kind = EntryTargetKind.fromWire(targetJson['kind'] as String?);
      final ref = targetJson['ref'] as String?;
      // An unrecognised kind or a missing ref leaves no target, which makes
      // the answer not-ok. Opening a guess is worse than not opening.
      if (kind != null && ref != null && ref.isNotEmpty) {
        target = EntryTargetRef(
          kind: kind,
          ref: ref,
          route: targetJson['route'] as String?,
          params: (targetJson['params'] as Map?)?.cast<String, dynamic>(),
        );
      }
    }

    final grantJson = json['grant'];
    EntryGrant? grant;
    if (grantJson is Map<String, dynamic>) {
      final token = grantJson['token'] as String?;
      final expires = DateTime.tryParse(grantJson['expiresAt'] as String? ?? '');
      if (token != null && expires != null) {
        grant = EntryGrant(
          token: token,
          expiresAt: expires,
          scope: (grantJson['scope'] as List?)?.whereType<String>().toList(),
        );
      }
    }

    final stewardJson = json['steward'];
    EntryStewardRef? steward;
    if (stewardJson is Map<String, dynamic>) {
      final kind = EntryTargetKind.fromWire(stewardJson['kind'] as String?);
      final ref = stewardJson['ref'] as String?;
      if (kind != null && ref != null && ref.isNotEmpty) {
        steward = EntryStewardRef(
          kind: kind,
          ref: ref,
          route: stewardJson['route'] as String?,
        );
      }
    }

    final noticeJson = json['notice'];
    EntryNotice? notice;
    if (noticeJson is Map<String, dynamic>) {
      final message = noticeJson['message'] as String?;
      if (message != null && message.isNotEmpty) {
        notice = EntryNotice.fromWire(noticeJson['kind'] as String?, message);
      }
    }

    return EntryTarget(
      status: status,
      issuer: issuer,
      target: target,
      identityPolicy:
          IdentityPolicy.fromWire(json['identityPolicy'] as String?),
      grant: grant,
      steward: steward,
      notice: notice,
      reason: json['reason'] as String?,
      validUntil: DateTime.tryParse(json['validUntil'] as String? ?? ''),
    );
  }

  /// The answer a host substitutes when it could not get one at all.
  static EntryTarget unreachable(String reason) => EntryTarget(
        status: EntryStatus.denied,
        issuer: const EntryIssuer(name: ''),
        reason: reason,
      );
}
