/// `JsToolIsolate` — wraps a flutter_js runtime that lives inside its
/// own Dart `Isolate`. The per-isolate runtime sidesteps flutter_js
/// 0.8.7's `JavascriptCoreRuntime._sendMessageDartFunc` static field
/// (jscore_runtime.dart:171) which is overwritten by every new
/// runtime constructor — that bug breaks every previously-attached
/// `setupBridge('hostInvoke', ...)` the moment a SECOND runtime spins
/// up in the same isolate. With each bundle's runtime parked in its
/// own isolate the static is per-isolate and no cross-bundle stomp
/// occurs.
///
/// Wire-up:
///
///   1. `JsToolIsolate()` spawns the worker. Worker creates its
///      `JavascriptRuntime` (with `xhr: false` so it doesn't try to
///      bind ServicesBinding inside the worker) and enables promise
///      handling. Worker sends its command `SendPort` back over the
///      init port and waits.
///   2. `attachHostBridge(atoms, allowedAtoms, dispatch)` ships the
///      bridge bootstrap + per-atom surface code into the worker,
///      and stores `dispatch` for resolving `host.*` calls. The
///      worker installs the JS-side bridge (`__hostCall` / pending
///      map) and a `setupBridge('hostInvoke', ...)` handler that
///      forwards `{uuid, atom, verb, args}` over the event port. The
///      main isolate listens, awaits the atom dispatch, then ships
///      the resolve/reject back to the worker.
///   3. `evaluate` / `evaluateAsync` ship the code to the worker and
///      await a reply over a fresh per-call `ReceivePort`.
///   4. `dispose` sends a `shutdown` command — worker tears down its
///      runtime and exits; main side closes ports.
///
/// The protocol stays as small as possible: every message is a `Map`
/// keyed by `Symbol`s (Dart-native cross-isolate messages support
/// `Symbol` keys), with a `_K` enum acting as a discriminator on the
/// `kind` field.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_js/extensions/handle_promises.dart';
import 'package:flutter_js/flutter_js.dart' as fjs;

import 'atom_category.dart';

/// Dispatcher signature — given an atom key + verb + args list, the
/// host computes the atom's return value (JSON-serializable). Errors
/// thrown from the dispatcher are forwarded to the worker as
/// `__hostReject` with the exception's string form.
typedef HostAtomDispatcher = Future<Object?> Function(
    String atomKey, String verb, List<Object?> args);

enum _K {
  ready,
  evaluate,
  evaluateAsync,
  evaluateResult,
  attachBridge,
  hostInvoke,
  hostResolve,
  hostReject,
  shutdown,
}

/// Owner-side handle for an isolate-hosted JS runtime.
class JsToolIsolate {
  JsToolIsolate._(this._isolate, this._cmdPort, this._eventPort,
      this._eventSub, this._replies, this._dispatcherRef);

  final Isolate _isolate;
  final SendPort _cmdPort;
  final ReceivePort _eventPort;
  final StreamSubscription<dynamic> _eventSub;
  // Pending `evaluate` / `evaluateAsync` replies keyed by request id.
  final Map<int, Completer<_EvalResult>> _replies;
  // Holder for the host atom dispatcher. We carry it inside a list
  // (a 1-slot box) so `attachHostBridge` can update it without
  // breaking the existing event handler's closure capture.
  final List<HostAtomDispatcher?> _dispatcherRef;
  int _nextReplyId = 0;
  bool _disposed = false;

  /// Spawn the worker isolate and wait for it to come up. After this
  /// returns the owner can call [evaluate] / [evaluateAsync] /
  /// [attachHostBridge].
  static Future<JsToolIsolate> spawn() async {
    final initPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerEntry,
      initPort.sendPort,
      errorsAreFatal: false,
    );
    final stream = initPort.asBroadcastStream();
    final first = await stream.first as Map;
    initPort.close();
    if (first[#kind] != _K.ready) {
      isolate.kill();
      throw StateError('JsToolIsolate worker did not signal ready');
    }
    final cmdPort = first[#cmd] as SendPort;
    final eventPort = ReceivePort();
    final replies = <int, Completer<_EvalResult>>{};
    final dispatcherRef = <HostAtomDispatcher?>[null];
    final sub = eventPort.listen((dynamic raw) {
      if (raw is! Map) return;
      final k = raw[#kind];
      if (k == _K.evaluateResult) {
        final replyId = raw[#replyId] as int;
        final c = replies.remove(replyId);
        if (c == null) return;
        c.complete(_EvalResult(
          stringResult: (raw[#stringResult] as String?) ?? '',
          isError: (raw[#isError] as bool?) ?? false,
        ));
      } else if (k == _K.hostInvoke) {
        final uuid = raw[#uuid] as String;
        final atom = raw[#atom] as String;
        final verb = raw[#verb] as String;
        final args = (raw[#args] as List?)?.cast<Object?>() ??
            const <Object?>[];
        final dispatch = dispatcherRef.first;
        if (dispatch == null) {
          cmdPort.send(<Symbol, dynamic>{
            #kind: _K.hostReject,
            #uuid: uuid,
            #message: 'host atom dispatcher not wired',
          });
          return;
        }
        // Dispatch async on the main isolate. Reply via cmdPort once
        // the dispatcher settles.
        Future<void>(() async {
          try {
            final result = await dispatch(atom, verb, args);
            cmdPort.send(<Symbol, dynamic>{
              #kind: _K.hostResolve,
              #uuid: uuid,
              #result: result,
            });
          } catch (e) {
            cmdPort.send(<Symbol, dynamic>{
              #kind: _K.hostReject,
              #uuid: uuid,
              #message: e.toString(),
            });
          }
        });
      }
    });
    return JsToolIsolate._(
      isolate, cmdPort, eventPort, sub, replies, dispatcherRef,
    );
  }

  /// True after [dispose] has run.
  bool get isDisposed => _disposed;

  /// Synchronous-feeling evaluate — ships the code to the worker and
  /// awaits the result via a per-call reply id. Worker runs sync
  /// `runtime.evaluate`; for Promise-returning code use
  /// [evaluateAsync].
  Future<_EvalResult> evaluate(String code, {String? sourceUrl}) {
    return _eval(code: code, sourceUrl: sourceUrl, kind: _K.evaluate);
  }

  /// Like [evaluate] but the worker resolves a returned Promise via
  /// flutter_js `handlePromise` before replying.
  Future<_EvalResult> evaluateAsync(String code, {String? sourceUrl}) {
    return _eval(code: code, sourceUrl: sourceUrl, kind: _K.evaluateAsync);
  }

  Future<_EvalResult> _eval({
    required String code,
    required String? sourceUrl,
    required _K kind,
  }) {
    if (_disposed) {
      throw StateError('JsToolIsolate disposed');
    }
    final replyId = _nextReplyId++;
    final completer = Completer<_EvalResult>();
    _replies[replyId] = completer;
    _cmdPort.send(<Symbol, dynamic>{
      #kind: kind,
      #replyId: replyId,
      #code: code,
      if (sourceUrl != null) #sourceUrl: sourceUrl,
    });
    return completer.future;
  }

  /// Install the host-bridge plumbing in the worker. After this
  /// returns, JS inside the worker can call `host.<atom>.<verb>(...)`
  /// and the main-side [dispatch] will be invoked.
  Future<void> attachHostBridge({
    required Iterable<AtomCategory> atoms,
    required Iterable<String> allowedAtoms,
    required HostAtomDispatcher dispatch,
  }) async {
    if (_disposed) {
      throw StateError('JsToolIsolate disposed');
    }
    _dispatcherRef[0] = dispatch;
    final filtered = <String, List<String>>{};
    for (final a in atoms) {
      if (!allowedAtoms.contains(a.key)) continue;
      filtered[a.key] = [for (final v in a.verbs) v.name];
    }
    final replyId = _nextReplyId++;
    final completer = Completer<_EvalResult>();
    _replies[replyId] = completer;
    _cmdPort.send(<Symbol, dynamic>{
      #kind: _K.attachBridge,
      #replyId: replyId,
      #atomVerbs: filtered,
      #eventPort: _eventPort.sendPort,
    });
    final result = await completer.future;
    if (result.isError) {
      throw StateError(
          'JsToolIsolate.attachHostBridge worker error: '
          '${result.stringResult}');
    }
  }

  /// Tear down the worker. Subsequent calls are no-ops.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _cmdPort.send(<Symbol, dynamic>{#kind: _K.shutdown});
    } catch (_) {/* swallow — worker may already be gone */}
    await _eventSub.cancel();
    _eventPort.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

class _EvalResult {
  _EvalResult({required this.stringResult, required this.isError});
  final String stringResult;
  final bool isError;
}

// ---------------------------------------------------------------------------
// Worker isolate code below — runs INSIDE the spawned isolate. No host atoms
// here; the worker only talks to main via the cmd/event ports.
// ---------------------------------------------------------------------------

/// JS bootstrap installed inside the worker — wires `host`, the
/// pending-promise map, and the `__hostCall` / `__hostResolve` /
/// `__hostReject` machinery. Mirrors `JsHostBridge._kBootstrapJs` so
/// the existing per-tool JS source contracts are preserved.
const String _kWorkerBootstrapJs = r'''
(function() {
  if (globalThis.__hostBridgeReady) return;
  globalThis.__hostBridgeReady = true;
  globalThis.__hostPending = {};
  globalThis.__hostNextUuid = 0;
  globalThis.host = {};
  globalThis.__hostResolve = function(uuid, jsonResult) {
    var p = globalThis.__hostPending[uuid];
    if (!p) return;
    delete globalThis.__hostPending[uuid];
    var v;
    try { v = JSON.parse(jsonResult); } catch (e) { v = null; }
    p.resolve(v);
  };
  globalThis.__hostReject = function(uuid, message) {
    var p = globalThis.__hostPending[uuid];
    if (!p) return;
    delete globalThis.__hostPending[uuid];
    p.reject(new Error(message));
  };
  globalThis.__hostCall = function(atom, verb, args) {
    var uuid = '_h' + (++globalThis.__hostNextUuid);
    return new Promise(function(resolve, reject) {
      globalThis.__hostPending[uuid] = { resolve: resolve, reject: reject };
      sendMessage(
        'hostInvoke',
        JSON.stringify({ uuid: uuid, atom: atom, verb: verb, args: args || [] }),
      );
    });
  };
})();
''';

String _atomSurfaceJsLine(String key, List<String> verbs) {
  final buf = StringBuffer();
  buf.writeln("host['$key'] = host['$key'] || {};");
  for (final v in verbs) {
    buf.writeln(
      "host['$key']['$v'] = function() { "
      "return __hostCall('$key', '$v', "
      'Array.prototype.slice.call(arguments)); };',
    );
  }
  return buf.toString();
}

void _workerEntry(SendPort initPort) {
  // Spin up runtime — no xhr binding so the worker doesn't try to
  // touch Flutter's ServicesBinding (which is not initialised in a
  // background isolate).
  final rt = fjs.getJavascriptRuntime(xhr: false);
  rt.enableHandlePromises();
  final cmd = ReceivePort();
  initPort.send(<Symbol, dynamic>{#kind: _K.ready, #cmd: cmd.sendPort});
  SendPort? eventPort;
  final shutdown = Completer<void>();
  // Event-driven dispatch — using `cmd.listen` (not `await for`) so
  // we can process `hostResolve` / `hostReject` messages WHILE an
  // earlier `evaluateAsync` is still awaiting its Promise. The
  // `await for` form would block the second message until the first
  // completes, deadlocking the host bridge round-trip.
  cmd.listen((dynamic raw) async {
    if (raw is! Map) return;
    final kind = raw[#kind];
    if (kind == _K.shutdown) {
      if (!shutdown.isCompleted) shutdown.complete();
      return;
    } else if (kind == _K.evaluate) {
      final replyId = raw[#replyId] as int;
      try {
        final result = rt.evaluate(
          raw[#code] as String,
          sourceUrl: raw[#sourceUrl] as String?,
        );
        eventPort?.send(<Symbol, dynamic>{
          #kind: _K.evaluateResult,
          #replyId: replyId,
          #stringResult: result.stringResult,
          #isError: result.isError,
        });
      } catch (e) {
        eventPort?.send(<Symbol, dynamic>{
          #kind: _K.evaluateResult,
          #replyId: replyId,
          #stringResult: e.toString(),
          #isError: true,
        });
      }
    } else if (kind == _K.evaluateAsync) {
      final replyId = raw[#replyId] as int;
      try {
        final pending = await rt.evaluateAsync(
          raw[#code] as String,
          sourceUrl: raw[#sourceUrl] as String?,
        );
        final settled = await rt.handlePromise(pending);
        eventPort?.send(<Symbol, dynamic>{
          #kind: _K.evaluateResult,
          #replyId: replyId,
          #stringResult: settled.stringResult,
          #isError: settled.isError,
        });
      } catch (e) {
        eventPort?.send(<Symbol, dynamic>{
          #kind: _K.evaluateResult,
          #replyId: replyId,
          #stringResult: e.toString(),
          #isError: true,
        });
      }
    } else if (kind == _K.attachBridge) {
      final replyId = raw[#replyId] as int;
      try {
        eventPort = raw[#eventPort] as SendPort;
        rt.evaluate(_kWorkerBootstrapJs, sourceUrl: '<host-bootstrap>');
        final atomVerbs = (raw[#atomVerbs] as Map).cast<String, dynamic>();
        for (final entry in atomVerbs.entries) {
          final verbs = (entry.value as List).cast<String>();
          rt.evaluate(
            _atomSurfaceJsLine(entry.key, verbs),
            sourceUrl: '<host-atom:${entry.key}>',
          );
        }
        rt.setupBridge('hostInvoke', (dynamic msg) {
          // flutter_js can hand back either the raw JSON string (when
          // JS does `sendMessage(channel, JSON.stringify(...))`) or an
          // already-parsed map (other code paths).
          Map<String, dynamic>? parsed;
          if (msg is String) {
            try {
              parsed = _decodeJsonMap(msg);
            } catch (_) {/* fall through */}
          } else if (msg is Map) {
            parsed = msg.cast<String, dynamic>();
          }
          if (parsed == null) return;
          eventPort?.send(<Symbol, dynamic>{
            #kind: _K.hostInvoke,
            #uuid: parsed['uuid']?.toString() ?? '',
            #atom: parsed['atom']?.toString() ?? '',
            #verb: parsed['verb']?.toString() ?? '',
            #args: (parsed['args'] as List?) ?? const <dynamic>[],
          });
        });
        eventPort?.send(<Symbol, dynamic>{
          #kind: _K.evaluateResult,
          #replyId: replyId,
          #stringResult: 'ok',
          #isError: false,
        });
      } catch (e) {
        eventPort?.send(<Symbol, dynamic>{
          #kind: _K.evaluateResult,
          #replyId: replyId,
          #stringResult: 'attachBridge failed: $e',
          #isError: true,
        });
      }
    } else if (kind == _K.hostResolve) {
      final uuid = raw[#uuid] as String;
      final result = raw[#result];
      try {
        final encoded = _jsonEncodeWorker(result);
        rt.evaluate(
          '__hostResolve(${_jsonEscape(uuid)}, ${_jsonEscape(encoded)});',
          sourceUrl: '<host-resolve>',
        );
      } catch (_) {/* swallow — worker eval errors handled inline */}
    } else if (kind == _K.hostReject) {
      final uuid = raw[#uuid] as String;
      final message = (raw[#message] as String?) ?? 'unknown error';
      try {
        rt.evaluate(
          '__hostReject(${_jsonEscape(uuid)}, ${_jsonEscape(message)});',
          sourceUrl: '<host-reject>',
        );
      } catch (_) {/* swallow */}
    }
  });
  // Block the worker entry until shutdown is signalled — keeps the
  // isolate alive so the listener stays bound to `cmd`.
  shutdown.future.then((_) {
    cmd.close();
    rt.dispose();
  });
}

Map<String, dynamic>? _decodeJsonMap(String s) {
  final v = _jsonDecode(s);
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.cast<String, dynamic>();
  return null;
}

String _jsonEncodeWorker(Object? value) => jsonEncode(value);
String _jsonEscape(String s) => jsonEncode(s);
Object? _jsonDecode(String s) => jsonDecode(s);
