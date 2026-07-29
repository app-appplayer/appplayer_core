/// Opening what an entry resolved to (platform spec 19 §9.4-§9.5).
///
/// Tiers differ in **chrome** — a dedicated device shows no gate the way a
/// general player does — but not in what a target *means*. "A server target is
/// an endpoint you register and open" is the same sentence everywhere, so it
/// lives here instead of being rewritten per tier.
library;

import '../bundle/bundle_ref.dart';
import '../core/app_player_core_service.dart';
import '../model/server_config.dart';
import '../session/app_session.dart';
import 'entry_target.dart';

import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show EntryContext, IdentityContext;

/// Resolves a local node's discovery identity to a registered server id.
///
/// Discovery is a host capability (17), so core cannot perform it — a tier
/// that can wires this, and a tier that cannot leaves `localServer` entries
/// honestly unopenable rather than silently dialling something else.
typedef LocalNodeResolver = Future<String> Function(String discoveryRef);

/// Why an entry could not be opened even though the resolver said it was fine.
class EntryOpenUnsupported implements Exception {
  EntryOpenUnsupported(this.kind, this.reason);
  final EntryTargetKind kind;
  final String reason;

  @override
  String toString() => 'EntryOpenUnsupported(${kind.wireName}): $reason';
}

/// Turns a resolved target into an open session.
class EntryOpener {
  EntryOpener({
    required AppPlayerCoreService core,
    LocalNodeResolver? resolveLocalNode,
  })  : _core = core,
        _resolveLocalNode = resolveLocalNode;

  final AppPlayerCoreService _core;
  final LocalNodeResolver? _resolveLocalNode;

  /// Stable id for a server learned from an entry.
  ///
  /// Derived from the endpoint so scanning the same medium twice reuses one
  /// registration instead of accumulating a row per scan.
  static String serverIdFor(String endpoint) => 'entry:$endpoint';

  Future<AppSession> open({
    required EntryTargetRef target,
    required EntryContext entry,
    IdentityContext? identity,
  }) async {
    switch (target.kind) {
      case EntryTargetKind.server:
        return _openServer(target.ref, entry, identity);

      case EntryTargetKind.localServer:
        final resolve = _resolveLocalNode;
        if (resolve == null) {
          throw EntryOpenUnsupported(
            target.kind,
            'this build cannot discover local nodes',
          );
        }
        // The node proves itself through discovery + probe (17); the entry
        // code vouches for nothing about it.
        final serverId = await resolve(target.ref);
        return _core.openAppFromServer(serverId, entry: entry,
            identity: identity);

      case EntryTargetKind.bundle:
        // Acquisition is a separate act (install ≠ run): by the time an entry
        // opens a bundle it is already installed, and this only renders it
        // with the entry attached.
        return _core.openAppFromBundle(
          BundleInstalledRef(target.ref),
          entry: entry,
          identity: identity,
        );

      case EntryTargetKind.listing:
        // A listing names something to acquire, not something to render. The
        // tier that ships a marketplace acquires it and opens the resulting
        // bundle; core deliberately has no path from a listing id to a screen.
        throw EntryOpenUnsupported(
          target.kind,
          'acquire the listing first, then open its bundle',
        );

      case EntryTargetKind.external:
        // Handing a phone number or a web page to the OS is chrome, not a
        // session. Returning something here would mean pretending we rendered
        // it.
        throw EntryOpenUnsupported(
          target.kind,
          'external targets are handled by the host, not opened as a session',
        );
    }
  }

  /// Open a server this host has **already registered**, with the entry
  /// attached.
  ///
  /// Distinct from a `server` target on purpose: that one carries an endpoint
  /// to register, this one carries an id that already exists. Feeding an
  /// existing id through the endpoint path would mint a second row named after
  /// the id — the two look alike as strings and mean opposite things.
  Future<AppSession> openRegisteredServer(
    String serverId, {
    required EntryContext entry,
    IdentityContext? identity,
  }) {
    return _core.openAppFromServer(serverId, entry: entry, identity: identity);
  }

  Future<AppSession> _openServer(
    String endpoint,
    EntryContext entry,
    IdentityContext? identity,
  ) async {
    final id = serverIdFor(endpoint);
    final existing = await _core.getServer(id);
    if (existing == null) {
      // Registering mirrors adding a server by hand — an entry is a way of
      // learning an address, not a different kind of connection.
      await _core.saveServer(
        ServerConfig(
          id: id,
          name: entry.issuer?.name.isNotEmpty == true
              ? entry.issuer!.name
              : endpoint,
          description: 'Opened from a scanned link',
          transportType: TransportType.streamableHttp,
          transportConfig: <String, dynamic>{'url': endpoint},
        ),
      );
    }
    return _core.openAppFromServer(id, entry: entry, identity: identity);
  }
}
