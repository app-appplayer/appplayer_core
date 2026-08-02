import 'dart:convert';

import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:brain_kernel/mcp_host.dart' show SharedResourceSubscriptions;
import 'package:mcp_client/mcp_client.dart' hide Logger;

import '../exceptions.dart';
import '../logging/logger.dart';

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
      _logger.debug('Registered binding',
          {'uri': uri, 'binding': binding});
    }

    // Initial read (FR-RES-003) — failures are logged but not propagated.
    try {
      final resource = await client.readResource(uri);
      if (resource.contents.isEmpty) return;
      final text = resource.contents.first.text;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        decoded.forEach((key, value) {
          runtime.stateManager.set(key, value);
        });
      }
    } catch (e) {
      _logger.warn('Initial resource read failed', {'uri': uri}, e);
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
        _logger.warn('unsubscribeAllFor: unsubscribe failed', {
          'uri': uri,
          'ownerKey': ownerKey,
        }, e);
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
  Future<void> reattach({
    required Client client,
    required MCPUIRuntime runtime,
    required String ownerKey,
  }) async {
    final uris = _active[ownerKey];
    if (uris == null || uris.isEmpty) return;
    for (final uri in List<String>.from(uris)) {
      try {
        await SharedResourceSubscriptions.subscribe(client, uri);
      } catch (e, st) {
        _logger.logError('resubscribe after reconnect failed', e, st,
            {'uri': uri, 'ownerKey': ownerKey});
        continue;
      }
      try {
        final resource = await client.readResource(uri);
        if (resource.contents.isEmpty) continue;
        final text = resource.contents.first.text;
        if (text == null) continue;
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          decoded.forEach(runtime.stateManager.set);
        }
      } catch (e) {
        _logger.warn('resubscribe initial read failed', {'uri': uri}, e);
      }
    }
    _logger.info('resubscribed after reconnect',
        {'ownerKey': ownerKey, 'count': uris.length});
  }

  /// Snapshot of active subscription URIs per ownerKey (test helper).
  Map<String, Set<String>> get activeSubscriptions =>
      <String, Set<String>>{for (final e in _active.entries) e.key: {...e.value}};
}
