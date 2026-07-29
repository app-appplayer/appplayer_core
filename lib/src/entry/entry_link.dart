/// Reading an entry code out of a link (platform spec 19 §3).
///
/// Shared by every tier: the plumbing that delivers a link differs per host,
/// what a link *means* does not.
library;

import 'package:flutter/foundation.dart';

/// Why a link was not accepted as an entry.
enum EntryLinkRejection {
  /// Not https. Public media must be app-link claimable, and a custom scheme
  /// fails silently on a device without the app (§3.1).
  notHttps,

  /// A host this build does not claim. Accepting it would let any site hand
  /// us a code to resolve against a registry we do not speak for.
  unclaimedHost,

  /// Right host, but not the entry path space (§3.4).
  notEntryPath,

  /// No code after the prefix.
  noCode,
}

/// A link that is an entry, or the reason it is not.
@immutable
class EntryLink {
  const EntryLink._(this.code, this.rejection);

  const EntryLink.accepted(String code) : this._(code, null);

  const EntryLink.rejected(EntryLinkRejection rejection)
      : this._(null, rejection);

  /// The opaque code. The link never says where it points — that is what lets
  /// a medium be rebound without reprinting it (§3.3).
  final String? code;

  final EntryLinkRejection? rejection;

  bool get isEntry => code != null;

  /// Parse [uri] against the hosts and path prefix this build claims.
  ///
  /// [claimedHosts] is exact-match on purpose. A suffix match would accept
  /// `evil-example.test` for `example.test`, and a build that resolves codes
  /// from a host it does not claim is resolving someone else's registry.
  ///
  /// Being asked to parse a link this build does not claim is **not** an
  /// error to hide: it returns a rejection so the host can fall through to
  /// whatever it normally does with a URL, rather than silently swallowing it.
  static EntryLink parse(
    Uri uri, {
    required Set<String> claimedHosts,
    required String pathPrefix,
  }) {
    if (uri.scheme != 'https') {
      return const EntryLink.rejected(EntryLinkRejection.notHttps);
    }
    if (!claimedHosts.contains(uri.host.toLowerCase())) {
      return const EntryLink.rejected(EntryLinkRejection.unclaimedHost);
    }

    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final prefix = pathPrefix.split('/').where((s) => s.isNotEmpty).toList();

    // Prefix first, then the code. Checking length first would report a wrong
    // path as "no code", which sends whoever debugs it looking at the issuer's
    // code space instead of at the path they actually got wrong.
    for (var i = 0; i < prefix.length; i++) {
      if (i >= segments.length || segments[i] != prefix[i]) {
        return const EntryLink.rejected(EntryLinkRejection.notEntryPath);
      }
    }
    if (segments.length <= prefix.length) {
      return const EntryLink.rejected(EntryLinkRejection.noCode);
    }

    // Everything after the prefix is the code. Joining rather than taking one
    // segment keeps the code space open — an issuer may partition it however
    // it likes, and this side stays ignorant of the shape, which is the point
    // of an opaque code.
    final code = segments.sublist(prefix.length).join('/');
    if (code.isEmpty) {
      return const EntryLink.rejected(EntryLinkRejection.noCode);
    }
    return EntryLink.accepted(code);
  }
}
