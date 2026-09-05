import 'dart:convert';

import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:brain_kernel/mcp_host.dart' show SharedResourceSubscriptions;
import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../exceptions.dart';
import '../logging/logger.dart';

/// What a [ResourceSubscriber.reattach] actually achieved.
///
/// Returned rather than only logged because the two numbers are the whole
/// point: a reattach that re-subscribed nothing is a device that has gone
/// quiet, and reporting the attempt count made that indistinguishable from
/// success.
class ReattachResult {
  const ReattachResult({this.resubscribed = 0, this.failed = 0});

  /// Resources whose `resources/subscribe` reached the server.
  final int resubscribed;

  /// Resources whose subscribe was refused or threw. The stream for these is
  /// still dead after the reattach.
  final int failed;

  /// True when the reattach had work to do and none of it landed.
  bool get isTotalFailure => resubscribed == 0 && failed > 0;
}

/// Handles MCP resource subscribe / unsubscribe, initial read, and runtime
/// binding registration (MOD-RUNTIME-004, FR-RES-001~004).
///
/// Tracks active subscriptions per `ownerKey` (typically a serverId) so the
/// orchestrator can unsubscribe all on close without the caller enumerating.
class ResourceSubscriber {
  ResourceSubscriber({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;
  final Map<String, Set<String>> _active = <String, Set<String>>{};

  /// FR-RES-001~003
  Future<void> subscribe({
    required Client client,
    required MCPUIRuntime runtime,
    required String uri,
    String? binding,
    String? ownerKey,
  }) async {
    _logger.debug('Subscribing resource',
        {'uri': uri, 'binding': binding, 'ownerKey': ownerKey});
    try {
      // Reference-counted: this client may be shared with a composed tile
      // naming the same device. The server knows only "subscribed" or not, so
      // whoever released first used to stop the other's stream.
      await SharedResourceSubscriptions.subscribe(client, uri);
    } catch (e, st) {
      _logger.logError('subscribeResource failed', e, st, {'uri': uri});
      throw ResourceSubscriptionException(uri, cause: e);
    }

    if (ownerKey != null) {
      _active.putIfAbsent(ownerKey, () => <String>{}).add(uri);
    }

    if (binding != null) {
      runtime.registerResourceSubscription(uri, binding);
      _logger.debug('Registered binding', {'uri': uri, 'binding': binding});
    }

    // Initial read (FR-RES-003) — failures are logged but not propagated.
    try {
      final resource = await client.readResource(uri);
      _apply(runtime, binding, resource);
    } catch (e) {
      _logger.warn('Initial resource read failed', {'uri': uri}, e);
    }
  }

  /// A one-shot read (spec §4.5 `resource read`): fetch and store at
  /// [binding]. No subscription, no reference count — a document that reads
  /// on every page open must not be holding one more wire subscription per
  /// open. Failures propagate: the action reports them.
  Future<void> read({
    required Client client,
    required MCPUIRuntime runtime,
    required String uri,
    required String binding,
  }) async {
    _logger.debug('Reading resource', {'uri': uri, 'binding': binding});
    final resource = await client.readResource(uri);
    _apply(runtime, binding, resource);
  }

  /// Stores what a read returned the way a notification does: the decoded
  /// payload **as-is at the binding** (spec §4.5). It used to spread the
  /// payload's top-level keys over the root state instead, so `live` — the
  /// binding a page declared and read — was never written by a read, only by
  /// the next `notifications/resources/updated`; a page opened before any
  /// notification stayed empty, and one re-entered later showed the previous
  /// notification's content. Without a binding the legacy spread stands.
  void _apply(
    MCPUIRuntime runtime,
    String? binding,
    ReadResourceResult resource,
  ) {
    if (resource.contents.isEmpty) return;
    final text = resource.contents.first.text;
    if (text == null) return;
    final decoded = jsonDecode(text);
    if (binding != null) {
      runtime.stateManager.set(binding, decoded);
      return;
    }
    if (decoded is Map<String, dynamic>) {
      decoded.forEach((key, value) {
        runtime.stateManager.set(key, value);
      });
    }
  }

  /// FR-RES-004
  Future<void> unsubscribe({
    required Client client,
    required MCPUIRuntime runtime,
    required String uri,
    String? ownerKey,
  }) async {
    _logger.debug('Unsubscribing resource', {'uri': uri});
    try {
      await SharedResourceSubscriptions.unsubscribe(client, uri);
    } catch (e, st) {
      _logger.logError('unsubscribeResource failed', e, st, {'uri': uri});
      throw ResourceSubscriptionException(uri, cause: e);
    }
    runtime.unregisterResourceSubscription(uri);
    if (ownerKey != null) {
      _active[ownerKey]?.remove(uri);
      if (_active[ownerKey]?.isEmpty ?? false) {
        _active.remove(ownerKey);
      }
    }
  }

  /// Unsubscribes every resource associated with [ownerKey]. Used by the
  /// orchestrator's `closeApp` path to prevent leaked subscriptions.
  Future<void> unsubscribeAllFor({
    required Client client,
    required MCPUIRuntime runtime,
    required String ownerKey,
  }) async {
    final uris = _active[ownerKey];
    if (uris == null || uris.isEmpty) return;
    for (final uri in List<String>.from(uris)) {
      try {
        await unsubscribe(
          client: client,
          runtime: runtime,
          uri: uri,
          ownerKey: ownerKey,
        );
      } catch (e) {
        _logger.warn(
            'unsubscribeAllFor: unsubscribe failed',
            {
              'uri': uri,
              'ownerKey': ownerKey,
            },
            e);
      }
    }
  }

  /// Re-issues every subscription recorded for [ownerKey] on a NEW client.
  ///
  /// A subscription belongs to the CONNECTION. After a background round trip
  /// the connection is torn down and rebuilt, and the server has no memory of
  /// what the previous link had subscribed — the stream simply stops. The
  /// runtime bindings, on the other hand, live in the runtime and survive, so
  /// nothing on screen looks wrong and pressing Subscribe again is a no-op
  /// from the runtime's point of view. Only the wire call has to be redone.
  ///
  /// Bindings are therefore NOT re-registered here; the initial read is, so
  /// the first value after a resume is current rather than whatever was on
  /// screen when the app went away.
  Future<ReattachResult> reattach({
    required Client client,
    required MCPUIRuntime runtime,
    required String ownerKey,
  }) async {
    final uris = _active[ownerKey];
    if (uris == null || uris.isEmpty) return const ReattachResult();
    var resubscribed = 0;
    var failed = 0;
    for (final uri in List<String>.from(uris)) {
      try {
        await SharedResourceSubscriptions.subscribe(client, uri);
        resubscribed++;
      } catch (e, st) {
        failed++;
        _logger.logError('resubscribe after reconnect failed', e, st,
            {'uri': uri, 'ownerKey': ownerKey});
        continue;
      }
      try {
        final resource = await client.readResource(uri);
        // The binding survived in the runtime; the read lands on it the
        // same way the initial read did.
        _apply(runtime, runtime.getBindingForUri(uri), resource);
      } catch (e) {
        _logger.warn('resubscribe initial read failed', {'uri': uri}, e);
      }
    }
    // Successes and failures, separately. This used to report the number of
    // URIs ATTEMPTED under the name `count`, so a reattach where every
    // resource was refused still printed `resubscribed … count: 2` with the
    // failures on their own earlier lines — which reads as success and was
    // misread as success by someone debugging a device that had gone quiet.
    _logger.info('resubscribed after reconnect', {
      'ownerKey': ownerKey,
      'resubscribed': resubscribed,
      'failed': failed,
    });
    return ReattachResult(resubscribed: resubscribed, failed: failed);
  }

  /// Snapshot of active subscription URIs per ownerKey (test helper).
  Map<String, Set<String>> get activeSubscriptions => <String, Set<String>>{
        for (final e in _active.entries) e.key: {...e.value}
      };
}
