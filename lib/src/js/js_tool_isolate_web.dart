/// Web branch of [JsToolIsolate] — the bundle's JavaScript runs in a Web
/// Worker, never on the page.
///
/// The native branch parks each bundle's engine in its own Dart `Isolate`.
/// The web has the same need and a different primitive: a Worker has its own
/// global scope and no DOM, so bundle JS cannot reach the document, the app's
/// state, storage or cookies. Evaluating on the main thread would hand it all
/// of those, so this branch does not offer that path at all.
///
/// The worker is created from a blob rather than a shipped script file so the
/// build stays a single artifact with nothing to serve alongside it. That
/// costs a hosting requirement, recorded here because it fails loudly and far
/// from its cause otherwise: the page's policy must permit `worker-src blob:`,
/// and the worker must be allowed `'unsafe-eval'` — running caller-supplied
/// JavaScript is the feature, and no policy makes that unnecessary.
///
/// Wire-up mirrors the native branch:
///
///   1. [JsToolIsolate.spawn] starts the worker and waits for its `ready`.
///   2. [attachHostBridge] ships the bootstrap + per-atom surface, then
///      answers each `hostInvoke` by dispatching the atom and posting back a
///      resolve or reject.
///   3. [evaluate] / [evaluateAsync] post code and await a reply keyed by a
///      call id.
///   4. [dispose] terminates the worker.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'atom_category.dart';
import 'js_bridge_protocol.dart';

/// Message kinds on the worker channel. Kept to strings because the payload
/// crosses a structured-clone boundary shared with plain JavaScript.
const String _kReady = 'ready';
const String _kEvaluate = 'evaluate';
const String _kEvaluateAsync = 'evaluateAsync';
const String _kEvaluateResult = 'evaluateResult';
const String _kHostInvoke = 'hostInvoke';
const String _kHostResolve = 'hostResolve';
const String _kHostReject = 'hostReject';

/// Owner-side handle for a worker-hosted JS runtime.
class JsToolIsolate {
  JsToolIsolate._(this._worker, this._subscription);

  final web.Worker _worker;
  final StreamSubscription<void> _subscription;

  final Map<int, Completer<JsIsolateEvalResult>> _replies = {};
  int _nextCallId = 0;

  HostAtomDispatcher? _dispatch;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// Starts the worker and completes once it reports readiness.
  static Future<JsToolIsolate> spawn() async {
    final blob = web.Blob(
      <JSString>[_workerSource.toJS].toJS,
      web.BlobPropertyBag(type: 'text/javascript'),
    );
    final url = web.URL.createObjectURL(blob);
    final worker = web.Worker(url.toJS);

    final ready = Completer<void>();
    late JsToolIsolate handle;

    final subscription = web.EventStreamProviders.messageEvent
        .forTarget(worker)
        .listen((event) {
          final data = _decode(event.data);
          if (data == null) return;
          final kind = data['kind'];
          if (kind == _kReady) {
            // The blob URL is only needed to start the worker.
            web.URL.revokeObjectURL(url);
            if (!ready.isCompleted) ready.complete();
          } else if (kind == _kEvaluateResult) {
            handle._completeEval(data);
          } else if (kind == _kHostInvoke) {
            handle._onHostInvoke(data);
          }
        });

    handle = JsToolIsolate._(worker, subscription);
    await ready.future;
    return handle;
  }

  /// Installs the host bridge and the `host.<atom>.<verb>` surface, and stores
  /// [dispatch] for resolving those calls.
  Future<void> attachHostBridge({
    required Iterable<AtomCategory> atoms,
    required Iterable<String> allowedAtoms,
    required HostAtomDispatcher dispatch,
  }) async {
    _ensureAlive();
    _dispatch = dispatch;

    final allowed = allowedAtoms.toSet();
    final buf = StringBuffer(_bootstrapJs);
    for (final atom in atoms) {
      if (!allowed.contains(atom.key)) continue;
      buf.writeln(
        atomSurfaceJsLine(atom.key, [for (final v in atom.verbs) v.name]),
      );
    }

    final result = await _eval(kind: _kEvaluate, code: buf.toString());
    if (result.isError) {
      throw StateError('host bridge install failed: ${result.stringResult}');
    }
  }

  Future<JsIsolateEvalResult> evaluate(String code, {String? sourceUrl}) =>
      _eval(kind: _kEvaluate, code: code, sourceUrl: sourceUrl);

  Future<JsIsolateEvalResult> evaluateAsync(String code, {String? sourceUrl}) =>
      _eval(kind: _kEvaluateAsync, code: code, sourceUrl: sourceUrl);

  Future<JsIsolateEvalResult> _eval({
    required String kind,
    required String code,
    String? sourceUrl,
  }) {
    _ensureAlive();
    final id = _nextCallId++;
    final completer = Completer<JsIsolateEvalResult>();
    _replies[id] = completer;
    _post({
      'kind': kind,
      'id': id,
      'code': code,
      if (sourceUrl != null) 'sourceUrl': sourceUrl,
    });
    return completer.future;
  }

  void _completeEval(Map<String, dynamic> data) {
    final id = data['id'];
    if (id is! int) return;
    final completer = _replies.remove(id);
    if (completer == null || completer.isCompleted) return;
    completer.complete(
      JsIsolateEvalResult(
        stringResult: (data['result'] as String?) ?? '',
        isError: data['isError'] == true,
      ),
    );
  }

  Future<void> _onHostInvoke(Map<String, dynamic> envelope) async {
    // The bootstrap ships the call as a JSON string so the JS side builds it
    // exactly as the native branch does.
    final raw = envelope['payload'];
    if (raw is! String) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return;
    final data = decoded;

    final uuid = data['uuid'] as String?;
    if (uuid == null) return;

    final dispatch = _dispatch;
    if (dispatch == null) {
      _post({
        'kind': _kHostReject,
        'uuid': uuid,
        'message': 'host bridge not attached',
      });
      return;
    }

    try {
      final value = await dispatch(
        (data['atom'] as String?) ?? '',
        (data['verb'] as String?) ?? '',
        (data['args'] as List?)?.cast<Object?>() ?? const <Object?>[],
      );
      _post({
        'kind': _kHostResolve,
        'uuid': uuid,
        'result': jsonEncode(value),
      });
    } catch (e) {
      // The dispatcher's failure is the bundle's to handle, not a crash of
      // the runtime — it comes back as a rejected Promise on the JS side.
      _post({'kind': _kHostReject, 'uuid': uuid, 'message': '$e'});
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _dispatch = null;
    for (final completer in _replies.values) {
      if (!completer.isCompleted) {
        completer.complete(
          JsIsolateEvalResult(
            stringResult: 'runtime disposed',
            isError: true,
          ),
        );
      }
    }
    _replies.clear();
    await _subscription.cancel();
    _worker.terminate();
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('JsToolIsolate disposed');
  }

  void _post(Map<String, dynamic> message) {
    if (_disposed) return;
    _worker.postMessage(jsonEncode(message).toJS);
  }

  static Map<String, dynamic>? _decode(JSAny? data) {
    if (data == null) return null;
    final text = (data as JSString).toDart;
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  }
}

/// Web branch ships `hostInvoke` through the worker's `postMessage`.
final String _bootstrapJs = hostBridgeBootstrapJs(
  "function(p) { postMessage(JSON.stringify("
  "{ kind: 'hostInvoke', payload: p })); }",
);

/// The worker program.
///
/// It owns no host state: it evaluates code, forwards `hostInvoke` outward and
/// applies the answers. Everything crossing the boundary is a JSON string, so
/// a bundle cannot hand the host a live JavaScript object.
const String _workerSource = r'''
self.__evalOnce = function(code, sourceUrl) {
  var wrapped = sourceUrl ? (code + '\n//# sourceURL=' + sourceUrl) : code;
  return (0, eval)(wrapped);
};

self.onmessage = function(event) {
  var msg;
  try { msg = JSON.parse(event.data); } catch (e) { return; }

  if (msg.kind === 'evaluate' || msg.kind === 'evaluateAsync') {
    var reply = function(result, isError) {
      postMessage(JSON.stringify({
        kind: 'evaluateResult',
        id: msg.id,
        result: result,
        isError: isError,
      }));
    };
    var value;
    try {
      value = self.__evalOnce(msg.code, msg.sourceUrl);
    } catch (e) {
      reply(String((e && e.message) || e), true);
      return;
    }
    if (msg.kind === 'evaluateAsync' && value && typeof value.then === 'function') {
      value.then(
        function(v) { reply(self.__stringify(v), false); },
        function(e) { reply(String((e && e.message) || e), true); }
      );
    } else {
      reply(self.__stringify(value), false);
    }
    return;
  }

  if (msg.kind === 'hostResolve') {
    if (self.__hostResolve) self.__hostResolve(msg.uuid, msg.result);
    return;
  }

  if (msg.kind === 'hostReject') {
    if (self.__hostReject) self.__hostReject(msg.uuid, msg.message);
    return;
  }
};

self.__stringify = function(v) {
  if (v === undefined) return '';
  if (typeof v === 'string') return v;
  try { return JSON.stringify(v); } catch (e) { return String(v); }
};

postMessage(JSON.stringify({ kind: 'ready' }));
''';
