// VENDORED from `os/core/brain_kernel/recipes/composition_host`.
//
// A copy, not a dependency: this package is published to pub.dev and the recipe
// is `publish_to: none`, so a path dependency on it would make this package
// unpublishable. The recipe stays the reference other hosts read and build
// against (Vibe Studio drives the runtime directly, without this core).
//
// Fix at the recipe and re-vendor — never edit only this copy, or the reference
// a second host is following stops describing what the platform actually does.
// The two files are identical below this header, so `diff` is the drift check.

import 'dart:async';
import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart'
    show KernelClientConnection, KernelClientHost;

/// Calls an in-process kernel tool (`mcp.read_resource`, `mcp.call_tool`, …).
///
/// Supplied by the host rather than taken as a dispatcher type so this recipe
/// stays independent of whichever dispatcher a host uses.
typedef KernelToolCall = Future<Object?> Function(
    String tool, Map<String, dynamic> args);

/// Opens a named origin the host is not currently connected to.
///
/// A document names an origin; it never opens one. Registering a device does
/// not hold a connection open either, and holding one would be wrong: several
/// boards serve a single peer at a time, so a permanent connection per
/// registered device has the last one to connect reset the others (measured on
/// the bench as `Connection reset by peer`). The host is the only party that
/// knows how to reach a device, so opening stays here.
typedef OpenOrigin = Future<void> Function(String connectionId);

/// Reads a definition on the host's own origin, for a source that names none.
typedef ReadOwnDefinition = Future<Map<String, dynamic>> Function(String uri);

/// The three hooks a runtime needs to implement the Composition Profile.
///
/// Deliberately one object: a host that wires only the resolver ships a
/// composed screen that renders and does nothing, because the controls inside
/// an embedded subtree take the app's own path and land on a session with no
/// client for that device. Rendering and acting are separate halves, and
/// handing them out together is what stops one shipping without the other.
class CompositionHooks {
  const CompositionHooks({
    required this.resolveDefinition,
    required this.callTool,
    required this.watchResource,
    required this.readResource,
  });

  /// `registerDefinitionResolver` — brings another origin's UI in.
  final Future<Map<String, dynamic>> Function(
      String ref, Map<String, dynamic> origin) resolveDefinition;

  /// `registerOriginToolCaller` — lets that UI act on its device.
  final Future<dynamic> Function(Map<String, dynamic> origin, String tool,
      Map<String, dynamic> params) callTool;

  /// `registerOriginResourceWatcher` — lets it track a changing value.
  /// Returns a disposer the runtime calls on unsubscribe.
  final Future<void Function()> Function(
    Map<String, dynamic> origin,
    String uri,
    void Function(dynamic contents) onUpdate,
  ) watchResource;

  /// `registerOriginResourceReader` — a ONE-SHOT read, leaving no watch behind.
  ///
  /// Separate from [watchResource] because a read that subscribes keeps a
  /// device pushing to a view that asked once, and a view that only reads
  /// should not make the device stream.
  final Future<Object?> Function(Map<String, dynamic> origin, String uri)
      readResource;
}

/// Builds the Composition Profile hooks over a kernel client host.
///
/// [call] drives the kernel's in-process `mcp.*` tools; [connections] is the
/// live client host (used for "is this origin already open" and for update
/// streams). [openOrigin] is asked for an origin the host does not hold yet;
/// [readOwn] serves a source that names no origin at all.
///
/// Every failure throws rather than falling back to the host's own origin: a
/// `view` turns a throw into its own fallback, while a silent substitution
/// would render one device's UI under another's identity (§7.10.1 rule 6).
CompositionHooks buildCompositionHooks({
  required KernelToolCall call,
  required KernelClientHost? Function() clientHost,
  OpenOrigin? openOrigin,
  ReadOwnDefinition? readOwn,
}) {
  String requireConnectionId(Map<String, dynamic> origin, String what) {
    final id = origin['connection'];
    if (id is! String || id.isEmpty) {
      throw StateError('$what: unsupported origin ${origin.keys.toList()}');
    }
    return id;
  }

  /// The LIVE connection for [connectionId], or null.
  ///
  /// Liveness, not mere presence: a host may still list a connection whose
  /// link is gone. Treating "the id is registered" as "the origin is open"
  /// makes a composed screen give up permanently — it never asks to reopen,
  /// while every call it makes lands on a connection that cannot carry one.
  /// The standalone path recovers on the next tap and the composed tile does
  /// not, which reads as "the device works alone but not in a multi-device
  /// screen".
  KernelClientConnection? liveConnection(String connectionId) {
    for (final c
        in clientHost()?.connections ?? const <KernelClientConnection>[]) {
      if (c.id == connectionId && c.isConnected) return c;
    }
    return null;
  }

  /// Definitions already fetched from an origin, keyed `<connection>|<ref>`.
  ///
  /// A device's UI document does not change while the host stays connected to
  /// it, but every mount used to re-read it: entering a composed screen cost
  /// `ui://app` + `ui://page/main` over the wire again, so a tile on a live
  /// connection still showed a spinner and looked like it was reconnecting.
  /// The standalone screen does not behave that way — leaving and coming back
  /// is immediate — and a composed tile has no reason to be slower.
  ///
  /// Dropped when the origin is (re)opened, which is the only moment the
  /// document could have changed under us: a device that rebooted with new UI
  /// necessarily got a new connection first.
  final definitions = <String, Map<String, dynamic>>{};

  void forgetDefinitions(String connectionId) {
    definitions.removeWhere((k, _) => k.startsWith('$connectionId|'));
  }

  Future<void> ensureOpen(String connectionId) async {
    if (liveConnection(connectionId) != null) return;
    if (openOrigin == null) return;
    forgetDefinitions(connectionId);
    await openOrigin(connectionId);
  }

  /// The connection object for [connectionId], opening it if needed. A tile can
  /// outlive the connection that resolved it — a board drops while its view is
  /// on screen — so this re-opens rather than failing the first call after.
  Future<KernelClientConnection> connectionFor(String connectionId) async {
    KernelClientConnection? find() => liveConnection(connectionId);

    final existing = find();
    if (existing != null) return existing;
    forgetDefinitions(connectionId);
    if (openOrigin != null) await openOrigin(connectionId);
    final opened = find();
    if (opened == null) {
      throw StateError('origin "$connectionId" is not connected');
    }
    return opened;
  }

  Future<Object?> readResource(String connectionId, String uri) =>
      call('mcp.read_resource', <String, dynamic>{
        'id': connectionId,
        'uri': uri,
      });

  return CompositionHooks(
    readResource: (origin, uri) async {
      final connectionId = requireConnectionId(origin, 'resource "$uri"');
      await ensureOpen(connectionId);
      return unwrapResourceContents(await readResource(connectionId, uri));
    },
    resolveDefinition: (ref, origin) async {
      if (origin.isEmpty) {
        if (readOwn == null) {
          throw StateError('view: no own-origin reader wired for "$ref"');
        }
        return readOwn(ref);
      }
      final connectionId = requireConnectionId(origin, 'view');
      await ensureOpen(connectionId);
      final key = '$connectionId|$ref';
      final cached = definitions[key];
      if (cached != null) return cached;
      final resolved = definitionFromReadResource(
          await readResource(connectionId, ref), ref);
      definitions[key] = resolved;
      return resolved;
    },
    callTool: (origin, tool, params) async {
      final connectionId = requireConnectionId(origin, 'tool "$tool"');
      await ensureOpen(connectionId);
      return call('mcp.call_tool', <String, dynamic>{
        'id': connectionId,
        'tool': tool,
        'args': params,
      });
    },
    watchResource: (origin, uri, onUpdate) async {
      final connectionId = requireConnectionId(origin, 'resource "$uri"');
      final connection = await connectionFor(connectionId);

      // Read once before watching. A subscription reports only CHANGES, so a
      // view that waits for one shows nothing until the value happens to move —
      // which for a slow reading is indistinguishable from a broken binding.
      try {
        onUpdate(unwrapResourceContents(await readResource(connectionId, uri)));
      } catch (_) {
        // A device that cannot serve the current value can still push updates.
      }

      final sub = connection.resourceUpdates.listen((changed) async {
        if (changed != uri) return;
        try {
          onUpdate(
              unwrapResourceContents(await readResource(connectionId, uri)));
        } catch (_) {
          // A failed refresh leaves the last value on screen rather than
          // blanking it; the next update tries again.
        }
      });

      await call('mcp.subscribe_resource', <String, dynamic>{
        'id': connectionId,
        'uri': uri,
      });

      return () {
        unawaited(sub.cancel());
        unawaited(call('mcp.unsubscribe_resource', <String, dynamic>{
          'id': connectionId,
          'uri': uri,
        }));
      };
    },
  );
}

/// Pulls the payload out of an MCP `resources/read` result.
///
/// A board serves its body as the `text` of a content item — the body is itself
/// JSON, escaped into the string — so the common case is one decode. A host
/// that already returns a decoded map is accepted as-is, and text that is not
/// JSON is returned as text rather than discarded.
Object? unwrapResourceContents(Object? raw) {
  Object? node = raw;
  if (node is Map && node['contents'] is List) {
    final contents = node['contents'] as List;
    if (contents.isEmpty) return null;
    node = contents.first;
  }
  if (node is Map && node['text'] is String) {
    final text = node['text'] as String;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }
  return node;
}

/// Same unwrap, narrowed to a UI definition.
///
/// Throws when the result is not one: a `view` renders its fallback on a throw,
/// whereas returning the error envelope as if it were a definition would put an
/// error document on screen as though the device had served it.
Map<String, dynamic> definitionFromReadResource(Object? raw, String ref) {
  final node = unwrapResourceContents(raw);
  if (node is Map<String, dynamic> && node['type'] is String) return node;
  if (node is Map && node['type'] is String) {
    return Map<String, dynamic>.from(node);
  }
  throw StateError('view: "$ref" did not resolve to a UI definition');
}
