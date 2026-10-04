import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;

import '../logging/logger.dart';
import '../model/server_config.dart';
import 'awaits_reachability.dart';
import 'connection_info.dart';
import 'connection_result.dart';
import 'connection_state.dart';
import 'serving_authorization.dart';
import 'shared_client.dart';
import 'transport_factory.dart';

/// Abstraction over `McpClient.createAndConnect` to allow injection in tests.
typedef ClientConnector = Future<Client> Function(TransportConfig transport);

/// Host-provided token re-grant for durable reconnect.
///
/// A marketplace server's credential is a short-lived per-user connectionToken
/// baked into [ServerConfig.transportConfig] `accessToken`. When a connect
/// attempt fails and the token may be stale, the manager calls this hook with
/// the stale config; the host re-grants a fresh token (silently, via the
/// marketplace session), persists it, and returns the refreshed [ServerConfig].
/// Returning null (or an unchanged token) means "no re-grant available" — the
/// original failure surfaces unchanged.
///
/// Optional: when no hook is wired, connect/reconnect behave exactly as before
/// (static token or no-auth). Only token-bearing servers whose host supplies a
/// hook are affected — hand-typed URLs, discovered boards (tcp/ble/serial) and
/// no-auth servers are untouched.
typedef ServerReGrant = Future<ServerConfig?> Function(ServerConfig stale);

/// Connects a streamable-HTTP server whose requests carry host-answered
/// credentials. Injected in tests; the default builds the protocol client on
/// the transport directly, the one place a per-request header provider and an
/// observing HTTP client can be handed in.
typedef AuthorizedConnector = Future<Client> Function(
  StreamableHttpTransportConfig transport,
  RequestHeadersProvider headers,
  http.Client httpClient,
);

Future<Client> _defaultAuthorizedConnector(
  StreamableHttpTransportConfig transport,
  RequestHeadersProvider headers,
  http.Client httpClient,
) async {
  final config = McpClient.simpleConfig(
    name: 'AppPlayer Client',
    version: '1.0.0',
  );
  final client = McpClient.createClient(config);
  final connection = await StreamableHttpClientTransport.create(
    baseUrl: transport.baseUrl,
    headers: transport.headers,
    headersProvider: headers,
    timeout: transport.timeout,
    maxConcurrentRequests: transport.maxConcurrentRequests,
    useHttp2: transport.useHttp2,
    httpClient: httpClient,
    terminateOnClose: transport.terminateOnClose,
  );
  await client.connectWithRetry(
    connection,
    maxRetries: config.maxRetries,
    delay: config.retryDelay,
  );
  return client;
}

bool _isHttp(String url) {
  final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

Future<Client> _defaultConnector(TransportConfig transport) async {
  final config = McpClient.simpleConfig(
    name: 'AppPlayer Client',
    version: '1.0.0',
  );
  final result = await McpClient.createAndConnect(
    config: config,
    transportConfig: transport,
  );
  if (result.isFailure) {
    throw StateError('Failed to connect: ${result.failureOrNull}');
  }
  return result.get();
}

/// Manages MCP server connections: create, reuse, disconnect, reconnect,
/// and notify listeners on state changes (MOD-CONN-001, FR-CONN-001~010).
class ConnectionManager extends ChangeNotifier {
  ConnectionManager({
    Logger? logger,
    TransportFactory? transportFactory,
    ClientConnector? connector,
    AuthorizedConnector? authorizedConnector,
    Duration? waitCheckInterval,
    Duration? waitMaxDuration,
  })  : _logger = logger ?? NoopLogger(),
        _transportFactory = transportFactory ?? const TransportFactory(),
        _connector = connector ?? _defaultConnector,
        _authorizedConnector =
            authorizedConnector ?? _defaultAuthorizedConnector,
        _waitCheckInterval =
            waitCheckInterval ?? const Duration(milliseconds: 100),
        _waitMaxDuration = waitMaxDuration ?? const Duration(seconds: 30);

  final Logger _logger;
  final TransportFactory _transportFactory;
  final ClientConnector _connector;
  final AuthorizedConnector _authorizedConnector;

  /// The host's answer to credentials for served addresses (see
  /// [ServingAuthorization]). Null = connections carry only what their
  /// [ServerConfig] says, byte-for-byte as before.
  ServingAuthorization? servingAuthorization;

  /// Other headers the host sends to served addresses (see [ServingHeaders]).
  ServingHeaders? servingHeaders;

  /// The person's language, when the host knows it better than the device —
  /// a tier with its own language setting answers it (FR-CONN-011). Asked when
  /// a connection is made; a null hook or a null answer sends the device's
  /// languages.
  String? Function()? requestLanguage;
  final Duration _waitCheckInterval;
  final Duration _waitMaxDuration;
  final Map<String, ConnectionInfo> _connections = {};

  /// Optional durable-reconnect hook (see [ServerReGrant]). Mutable so the host
  /// can wire it after the marketplace session exists (the core / manager is
  /// built at composition time, before the marketplace capabilities). Null =
  /// no re-grant; connect/reconnect stay byte-for-byte as before.
  ServerReGrant? tokenReGrant;

  /// Called after a server's [Client] is replaced by a NEW one — the first
  /// connect and every reconnect alike.
  ///
  /// State that lives on the CLIENT does not survive the swap: notification
  /// handlers and `resources/subscribe` are per-connection, so an open app
  /// that was streaming goes silent after a background round trip while its
  /// tool calls keep working (those resolve the live client per call). The
  /// screen looked healthy and only the stream was dead, and pressing
  /// Subscribe again did nothing because the runtime had already registered
  /// its binding. Whoever owns that state re-attaches here.
  void Function(String serverId, Client client)? onClientAttached;

  Map<String, ConnectionInfo> get connections => Map.unmodifiable(_connections);

  bool hasConnection(String serverId) => _connections.containsKey(serverId);

  ConnectionInfo? getConnection(String serverId) => _connections[serverId];

  /// FR-CONN-001~003, 010
  Future<ConnectionResult> connect(ServerConfig server) =>
      // Allow one durable-reconnect re-grant on the outer attempt; the retry
      // (with a fresh token) runs with allowReGrant:false so a persistently
      // bad server can't loop.
      _connect(server, allowReGrant: true);

  Future<ConnectionResult> _connect(
    ServerConfig server, {
    required bool allowReGrant,
  }) async {
    final existing = _connections[server.id];
    if (existing != null) {
      if (existing.state == ConnectionState.connected) {
        _logger.debug('Reusing connection', {'serverId': server.id});
        return ConnectionResult.success(existing);
      }
      if (existing.state == ConnectionState.connecting) {
        _logger.debug('Awaiting in-flight connection', {'serverId': server.id});
        return _waitForConnection(server.id);
      }
    }

    _logger.debug('Creating connection', {'serverId': server.id});
    final info = ConnectionInfo(
      serverId: server.id,
      serverName: server.name,
      serverConfig: server,
      state: ConnectionState.connecting,
    );
    _connections[server.id] = info;
    notifyListeners();

    try {
      final transport = _transportFactory.create(
        server,
        acceptLanguage: requestLanguage?.call() ??
            acceptLanguageOf(PlatformDispatcher.instance.locales),
      );
      final auth = servingAuthorization;
      final extra = servingHeaders;
      final Client connected;
      UnauthorizedHandler? onUnauthorized;
      // Credentials are an HTTP matter. A board-wire address (tcp / ble /
      // serial on a streamable-HTTP config) is a device the host's connector
      // dials; it has no request to put a header on (FR-CONN-012).
      if ((auth != null || extra != null) &&
          transport is StreamableHttpTransportConfig &&
          _isHttp(transport.baseUrl)) {
        // The host is asked before every request, so a person who signs in
        // mid-session is carried by the next call without reconnecting.
        final endpoint = Uri.parse(transport.baseUrl);
        final recorder = ChallengeRecordingClient();
        connected = await _authorizedConnector(
          transport,
          (request) async {
            final url = Uri.parse(request.url);
            final header = await auth?.authorizationFor(url);
            return <String, String>{
              if (extra != null) ...await extra.headersFor(url),
              if (header != null) 'Authorization': header,
            };
          },
          recorder,
        );
        if (auth != null) {
          onUnauthorized = () async =>
              await auth.afterUnauthorized(
                endpoint,
                wwwAuthenticate: recorder.takeChallenge(),
              ) !=
              null;
        }
      } else {
        connected = await _connector(transport);
      }
      // One connection, many consumers: this host's screens and whoever it
      // lends the connection to. Whatever the connector built is shared through
      // one layer, so the device does not feel them (23 §6.1).
      final client = SharedClient(
        connected,
        _sharingFor(server),
        onUnauthorized: onUnauthorized,
      );
      info.client = client;
      info.state = ConnectionState.connected;
      info.connectedAt = DateTime.now();
      // Liveness: when the transport drops on its own — BLE supervision
      // timeout, a server closing the socket — mcp_client fires onDisconnect.
      // Without reacting, this entry stays `connected` forever: the launcher
      // badge stays lit and a retry reuses the dead client (readResource hangs
      // on a link that is gone) instead of dialing again. React by dropping
      // the entry so hasConnection()/isServerConnected() tell the truth and the
      // next connect() starts fresh.
      info.disconnectSub = client.onDisconnect.listen((reason) {
        // Only this client's own death drops the entry. A late event from a
        // client that has already been replaced must not take down the
        // healthy one that replaced it.
        if (!identical(_connections[server.id]?.client, client)) return;
        _handleTransportDrop(server.id, reason);
      });
      notifyListeners();
      // After the entry is live, so a re-attach can resolve the connection it
      // is re-attaching to.
      final attached = onClientAttached;
      if (attached != null) {
        try {
          attached(server.id, client);
        } catch (e, st) {
          _logger.logError(
              'onClientAttached hook threw', e, st, {'serverId': server.id});
        }
      }

      _logger.info('Connected', {'serverId': server.id});
      return ConnectionResult.success(info);
    } catch (e, st) {
      // Durable reconnect (MOD-CONN): a marketplace server's connectionToken is
      // a short-lived per-user JWS baked into transportConfig. If it went stale
      // the connect (MCP initialize) fails auth. When a re-grant hook is wired
      // AND this server carries a bearer token, refresh it once and retry — the
      // fresh open re-initialises with a valid token. This runs for
      // openAppFromServer, reconnect() and ConnectionHealthMonitor alike, since
      // all three funnel through connect(). No hook / no token → skipped, and
      // the original failure surfaces unchanged (byte-for-byte prior behaviour).
      if (allowReGrant && tokenReGrant != null && _hasBearerToken(server)) {
        final fresh = await _reGrant(server);
        if (fresh != null) {
          _connections.remove(server.id);
          notifyListeners();
          return _connect(fresh, allowReGrant: false);
        }
      }
      info.state = ConnectionState.error;
      info.error = e.toString();
      info.awaitsReachability = e is AwaitsReachability;
      notifyListeners();
      _logger.logError('Connect failed', e, st, {'serverId': server.id});
      return ConnectionResult.failure(e.toString());
    }
  }

  bool _hasBearerToken(ServerConfig server) =>
      (server.transportConfig['accessToken'] as String?)?.isNotEmpty ?? false;

  /// Invoke the host re-grant hook. Returns a refreshed [ServerConfig] only when
  /// the hook produced a genuinely new token; otherwise null (→ surface the
  /// original failure). Hook errors are swallowed to a null so a failing
  /// re-grant never masks the real connect error.
  Future<ServerConfig?> _reGrant(ServerConfig stale) async {
    try {
      final fresh = await tokenReGrant!(stale);
      if (fresh != null &&
          fresh.transportConfig['accessToken'] !=
              stale.transportConfig['accessToken']) {
        _logger.info('Re-granted server token — retrying connect',
            {'serverId': stale.id});
        return fresh;
      }
    } catch (e, st) {
      _logger.logError('Token re-grant failed', e, st, {'serverId': stale.id});
    }
    return null;
  }

  /// Transport dropped on its own (not an explicit [disconnect] call). Mark the
  /// entry `error` and clear the dead client, but KEEP it in the map so:
  ///   - `isServerConnected` reads false (state != connected) → the launcher
  ///     badge clears and any open session's dynamic `client` getter goes null
  ///     instead of dialing a corpse;
  ///   - [ConnectionHealthMonitor] sees the `error` state and auto-reconnects,
  ///     which is what lets a flaky link (e.g. the ESP32 BLE controller that
  ///     hard-drops every ~45s) self-heal without the user reopening the app —
  ///     a fresh client lands back under the same serverId and the session
  ///     picks it up.
  /// Removing the entry instead would hide it from the monitor and there would
  /// be nothing to reconnect. Idempotent.
  void _handleTransportDrop(String serverId, DisconnectReason reason) {
    final info = _connections[serverId];
    if (info == null) return;
    info.disconnectSub?.cancel();
    info.disconnectSub = null;
    // Close the dead client before letting go of it. Dropping only the
    // reference leaves its socket open: the peer has already closed its side,
    // so the socket sits in CLOSE_WAIT for the life of the process, and the
    // reconnect that follows cannot close it either — `disconnect` finds no
    // client to close. Every keepalive miss leaked one. Measured 2026-09-16
    // against an ESP32 node: 36 sockets in CLOSE_WAIT within minutes, which
    // filled the board's own socket table until it reset new connections —
    // and each reset was another miss, so the leak fed itself.
    //
    // The listener is already cancelled above, so closing here cannot re-enter
    // this handler. Closing is best effort: a client that throws on the way
    // out must not stop the entry from being marked for reconnect.
    final dead = info.client;
    info.client = null;
    try {
      dead?.disconnect();
    } catch (e, st) {
      _logger.logError(
          'Closing a dropped client failed', e, st, {'serverId': serverId});
    }
    info.state = ConnectionState.error;
    info.error = 'transport dropped: $reason';
    _logger.info('Transport dropped — marked for reconnect',
        {'serverId': serverId, 'reason': reason.toString()});
    notifyListeners();
  }

  /// Active keepalive + liveness for transient stream transports (ble:// /
  /// tcp:// / serial:// carried on a streamableHttp config). Sends a cheap
  /// `ping` round-trip on every such CONNECTED link (any reply counts, see the
  /// probe below):
  ///   - the traffic keeps the link warm — an idle BLE session to an ESP32
  ///     drops in ~15s, but ~2-3s keepalive traffic stretches it to ~45s
  ///     (measured), so far fewer reconnect cycles;
  ///   - a probe that fails/times out means the link died silently, so the
  ///     entry is marked error (via [_handleTransportDrop]) and the health
  ///     monitor reconnects it.
  /// HTTP/SSE/stdio servers are skipped — they don't suffer idle-drop and a
  /// periodic poll would just be noise.
  Future<void> keepAliveSweep({
    Duration timeout = const Duration(seconds: 4),
    Duration dropAfterSilence = _silenceToDrop,
  }) async {
    // One sweep at a time. The health monitor fires on a timer and does not
    // wait for the previous tick, so a slow probe let sweeps pile up; when they
    // expired together each dropped the link again — the same connection was
    // logged as dropped three times in one second, over and over, on an ESP32
    // node that was answering.
    if (_sweeping) return;
    _sweeping = true;
    try {
      final targets = _connections.entries
          .where((e) =>
              e.value.state == ConnectionState.connected &&
              e.value.client != null &&
              _isTransientStream(e.value.serverConfig))
          .toList();
      for (final e in targets) {
        final serverId = e.key;
        final client = e.value.client!;
        // Anything the device sent is proof of life (23 §6.1.2). A link that
        // is streaming does not need a probe, and a probe on a busy single-task
        // device only queues behind the traffic that already answers the
        // question. Measured 2026-09-21: an ESP32 pushing an update every
        // second was dropped 23 times because its ping answers came late, and
        // every drop stopped the stream on all seven devices sharing it.
        final probeFrom = DateTime.now();
        final last = client is SharedClient ? client.lastMessageAt : null;
        if (last != null && probeFrom.difference(last) < timeout) {
          continue;
        }
        final limit = _probeLimit(serverId, timeout);
        final watch = Stopwatch()..start();
        // The probe is `ping`, and any answer is life — a result, or a JSON-RPC
        // error reply (it carries a code), which a device that never
        // implemented ping still sends. Only a timeout or a failure with no
        // reply behind it counts against the link.
        //
        // It used to be `resources/list`, every two seconds. On a small board
        // that serialises its whole resource list per call and serves one
        // request at a time, that was load the check itself added: measured
        // under two clients, list answers drifted to 1.2–2.6 s and sometimes
        // past the limit twice in a row, while the same board answered a ping
        // it does not even implement in 0.2 s.
        //
        // A client may throw on the call itself rather than fail its future;
        // both are the same attempt.
        Future<void> probe;
        try {
          probe = client.ping().then<void>((_) {}, onError: (Object e) {
            if (e is McpError && e.code != null) return; // it answered
            throw e;
          });
        } catch (e) {
          probe = Future<void>.error(e);
        }
        // Whether a missed probe was a lost answer or a late one decides the
        // fix — a longer wait, or a look elsewhere — so keep watching the
        // original request after giving up on it and say when, if ever, it came.
        unawaited(probe.then((_) {
          _recordProbe(serverId, watch.elapsed);
          if (watch.elapsed > limit) {
            // A late answer is still an answer: the device is alive, only slow.
            // Counting the miss anyway dropped an ESP32 that had answered both
            // of its "missed" probes — at 7.9 s and 4.4 s — one tick before the
            // second timeout was judged.
            _logger.info('Keepalive answer arrived late', {
              'serverId': serverId,
              'afterMs': watch.elapsedMilliseconds,
            });
          } else if (watch.elapsedMilliseconds > 1000) {
            _logger.info('Keepalive answer slow', {
              'serverId': serverId,
              'afterMs': watch.elapsedMilliseconds,
            });
          }
        }, onError: (Object _) {}));
        try {
          await probe.timeout(limit);
        } catch (error) {
          // Judge the client that was probed, not whatever holds the id now:
          // by the time a probe times out the link may already have been
          // replaced, and dropping the replacement starts the cycle again.
          if (!identical(_connections[serverId]?.client, client)) {
            _logger.info('Keepalive miss on a replaced client — ignored', {
              'serverId': serverId,
              'afterMs': watch.elapsedMilliseconds,
            });
            continue;
          }
          // A timeout says "slow or dead" and cannot tell which; one slow
          // answer is not a dead link. Measured on an ESP32 node under two
          // clients' load: keepalive answers drifted to 1.2–2.6 s, one crossed
          // the 4 s line, and dropping on that single miss cut a board that
          // answered the next probe normally — failing the press in flight.
          // A request that *errors* is different: the link refused it, so that
          // still drops at once.
          // Late is not dead: if anything arrived while the probe waited, the
          // link is alive and only this answer is slow (23 §6.1.2).
          final heard = client is SharedClient ? client.lastMessageAt : null;
          if (error is TimeoutException &&
              heard != null &&
              heard.isAfter(probeFrom)) {
            _logger.info('Keepalive answer late — link active', {
              'serverId': serverId,
              'afterMs': watch.elapsedMilliseconds,
            });
            continue;
          }
          // A missed probe is not the verdict; silence is. The link is called
          // dead only when nothing at all has come back for [dropAfterSilence].
          // Counting misses against an RTT-scaled wait dropped a board whose
          // answers were only held up by radio retransmission: the wait shrank
          // to 4.2 s on a good minute, two lost frames cost 4.5 s, and the
          // fourth such miss cut a link TCP would have delivered (2026-09-21).
          // A new connection rides the same radio, so it cannot do better.
          if (error is TimeoutException) {
            final since = heard ?? e.value.connectedAt ?? probeFrom;
            final silent = DateTime.now().difference(since);
            if (silent < dropAfterSilence) {
              _logger.info('Keepalive answer missed — keeping the link', {
                'serverId': serverId,
                'afterMs': watch.elapsedMilliseconds,
                'silentMs': silent.inMilliseconds,
              });
              continue;
            }
          }
          // Say why. A drop with no reason left a day of measurement guessing
          // between the board, the network and this side.
          _logger.info('Keepalive probe failed', {
            'serverId': serverId,
            'afterMs': watch.elapsedMilliseconds,
            'error': error.toString(),
          });
          _handleTransportDrop(serverId, DisconnectReason.transportError);
        }
      }
    } finally {
      _sweeping = false;
    }
  }

  bool _sweeping = false;

  /// Smoothed probe round trip per server — the device's own pace.
  final Map<String, Duration> _probeRtt = {};

  /// The wait for one probe: four times this device's measured round trip,
  /// never below the caller's floor and never past [_probeLimitCeiling]. A
  /// fixed line judged a slow device by a fast device's clock (23 §6.1.2).
  Duration _probeLimit(String serverId, Duration floor) {
    final rtt = _probeRtt[serverId];
    if (rtt == null) return floor;
    final scaled = rtt * 4;
    if (scaled < floor) return floor;
    if (scaled > _probeLimitCeiling) return _probeLimitCeiling;
    return scaled;
  }

  void _recordProbe(String serverId, Duration took) {
    final prev = _probeRtt[serverId];
    _probeRtt[serverId] = prev == null
        ? took
        : Duration(
            microseconds: (prev.inMicroseconds * 7 + took.inMicroseconds) ~/ 8);
  }

  static const Duration _probeLimitCeiling = Duration(seconds: 20);

  /// How long a link may send nothing at all before it is called dead.
  ///
  /// Longer than lwIP's retransmission ladder on a lossy 2.4 GHz link
  /// (1.5 + 3 + 6 + 12 s): a board whose frames are being retransmitted is
  /// alive, and TCP delivers what it sent. A streaming board speaks every
  /// second, so thirty silent seconds is not a slow answer. A transport that
  /// actually closes is still dropped at once through `onDisconnect`.
  static const Duration _silenceToDrop = Duration(seconds: 30);

  /// How a connection is shared (23 §6.1). A serving device — a board on a
  /// stream transport, or a device borrowed from another host — has a surface
  /// fixed for the connection: its lists and documents are read once. A board
  /// serves one request at a time, so it gets one at a time; the rest wait
  /// here. A general server keeps only what it promised to announce.
  ///
  /// The device's own declaration of its capacity should replace the tier
  /// default once the serving manifest carries it.
  static ConnectionSharing _sharingFor(ServerConfig server) {
    final base = server.transportType == TransportType.streamableHttp
        ? server.transportConfig['baseUrl']
        : null;
    final board = _isTransientStream(server);
    final borrowed = base is String && base.startsWith('peer://');
    return ConnectionSharing(
      surfaceFixed: board || borrowed,
      maxInFlight: board ? 1 : null,
    );
  }

  static bool _isTransientStream(ServerConfig server) {
    if (server.transportType != TransportType.streamableHttp) return false;
    final base = server.transportConfig['baseUrl'];
    return base is String &&
        (base.startsWith('ble://') ||
            base.startsWith('tcp://') ||
            base.startsWith('serial://'));
  }

  /// Who holds each connection — this host's app screen, each lent session.
  /// Letting go is counted (23 §6.1.4): one holder leaving must not close a
  /// connection others are still using.
  final Map<String, Set<String>> _holders = {};

  /// [holder] uses the connection of [serverId]. Idempotent per holder.
  void retain(String serverId, String holder) =>
      (_holders[serverId] ??= <String>{}).add(holder);

  /// [holder] is done with [serverId]. The connection closes only when the
  /// last holder lets go.
  Future<void> release(String serverId, String holder) async {
    final holders = _holders[serverId];
    holders?.remove(holder);
    if (holders != null && holders.isNotEmpty) {
      _logger.debug('Released — still held', {
        'serverId': serverId,
        'holder': holder,
        'holders': holders.length,
      });
      return;
    }
    _holders.remove(serverId);
    await disconnect(serverId);
  }

  /// Whether anyone holds [serverId]. A short-lived use (a metadata read, an
  /// open that gave up) closes the connection only when nobody does.
  bool isHeld(String serverId) => _holders[serverId]?.isNotEmpty ?? false;

  /// FR-CONN-004 — close [serverId] now, whoever holds it. For taking a device
  /// away (card removed, lending withdrawn — 23 §6); letting go is [release].
  Future<void> disconnect(String serverId) async {
    _holders.remove(serverId);
    await _teardown(serverId);
  }

  /// Close [serverId] for a while — the host is paused — keeping who holds
  /// it. Resuming dials again for the same holders.
  Future<void> suspend(String serverId) => _teardown(serverId);

  /// Close the client and drop the entry, keeping who holds it: a reconnect
  /// replaces the connection, its holders have not left.
  Future<void> _teardown(String serverId) async {
    final info = _connections[serverId];
    if (info == null) return;

    _logger.debug('Disconnecting', {'serverId': serverId});
    // Cancel the liveness listener first so tearing the client down does not
    // re-enter _handleTransportDrop for a disconnect we are performing.
    await info.disconnectSub?.cancel();
    info.disconnectSub = null;
    try {
      info.client?.disconnect();
    } catch (e, st) {
      _logger.warn('Disconnect error', {'serverId': serverId}, e);
      _logger.logError('Disconnect stack', e, st, {'serverId': serverId});
    }

    _connections.remove(serverId);
    notifyListeners();
  }

  /// FR-CONN-005
  Future<void> disconnectAll() async {
    _logger.debug('Disconnecting all', {'count': _connections.length});
    for (final info in _connections.values) {
      await info.disconnectSub?.cancel();
      info.disconnectSub = null;
      try {
        info.client?.disconnect();
      } catch (e) {
        _logger.warn('Disconnect error', {'serverId': info.serverId}, e);
      }
    }
    _connections.clear();
    notifyListeners();
  }

  /// FR-CONN-006
  Future<ConnectionResult> reconnect(String serverId) async {
    final existing = _connections[serverId];
    if (existing == null) {
      return ConnectionResult.failure('No connection found for server');
    }
    final server = existing.serverConfig;
    await _teardown(serverId);
    return connect(server);
  }

  /// FR-CONN-003, 010
  Future<ConnectionResult> _waitForConnection(String serverId) async {
    // Iteration-based loop (not wall clock) so it behaves correctly under
    // fakeAsync in tests.
    final maxIterations = _waitCheckInterval.inMilliseconds == 0
        ? 1
        : _waitMaxDuration.inMilliseconds ~/ _waitCheckInterval.inMilliseconds;

    for (var i = 0; i < maxIterations; i++) {
      final info = _connections[serverId];
      if (info == null) {
        return ConnectionResult.failure('Connection cancelled');
      }
      if (info.state == ConnectionState.connected) {
        return ConnectionResult.success(info);
      }
      if (info.state == ConnectionState.error) {
        return ConnectionResult.failure(info.error ?? 'Connection failed');
      }
      await Future<void>.delayed(_waitCheckInterval);
    }

    return ConnectionResult.failure('Connection timeout');
  }
}
