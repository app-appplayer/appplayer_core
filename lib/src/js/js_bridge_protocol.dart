/// The JS-side host bridge contract, shared by every platform branch of
/// [JsToolIsolate].
///
/// Bundle JS calls `host.<atom>.<verb>(...)`, which returns a Promise. The
/// bootstrap below turns that into a `hostInvoke` message carrying
/// `{uuid, atom, verb, args}`; the host dispatches the atom and answers with
/// `__hostResolve(uuid, json)` or `__hostReject(uuid, message)`.
///
/// Only the *transport* differs per platform — a Dart isolate port on native,
/// a worker `postMessage` on the web — so the JS contract lives here and each
/// branch supplies the one expression that ships the message out. Keeping this
/// in one place is what makes a bundle's JS behave identically on both.
library;

/// Dispatcher signature — given an atom key + verb + args list, the host
/// computes the atom's return value (JSON-serializable). Errors thrown from
/// the dispatcher are forwarded to the JS side as `__hostReject` with the
/// exception's string form.
///
/// [nonJson] lists the arguments JSON could not carry. They arrive in [args]
/// as `null`; a non-empty list means the call is refused, never dispatched
/// with the substituted value.
typedef HostAtomDispatcher = Future<Object?> Function(
  String atomKey,
  String verb,
  List<Object?> args,
  List<NonJsonArgument> nonJson,
);

/// One argument, or a part of one, that JSON cannot carry: a function, a
/// symbol, a bigint, `NaN`, `Infinity`, or a structure that contains itself.
///
/// `undefined` is not one of them — it crosses as `null`, and an object
/// property holding it is omitted, as `JSON.stringify` does.
class NonJsonArgument {
  const NonJsonArgument(this.path, this.kind);

  /// Reads the bridge's wire form, `{path: [0, "a", 1], kind: "function"}`.
  factory NonJsonArgument.fromWire(Object? raw) {
    final map = raw is Map ? raw : const {};
    final path = map['path'];
    return NonJsonArgument(
      path is List ? List<Object>.unmodifiable(path.whereType<Object>()) : const [],
      '${map['kind'] ?? 'unknown'}',
    );
  }

  /// Where it sits: the argument index first, then keys and indexes into it.
  final List<Object> path;

  /// `function` · `symbol` · `bigint` · `NaN` · `Infinity` · `-Infinity` ·
  /// `cycle`.
  final String kind;

  /// The argument index, or -1 when the path is empty.
  int get argumentIndex => path.isNotEmpty && path.first is int ? path.first as int : -1;

  /// `1.items.0` style, for messages.
  String get where => path.join('.');

  static List<NonJsonArgument> listFromWire(Object? raw) =>
      raw is List ? [for (final e in raw) NonJsonArgument.fromWire(e)] : const [];
}

/// An atom that names its own error for an argument JSON cannot carry —
/// `kb` answers `KB_INVALID_KEY` or `KB_INVALID_VALUE`. An atom that does not
/// implement this is refused with [defaultNonJsonRefusal].
abstract interface class NonJsonArgumentPolicy {
  /// The error to reject the call with. Never dispatches.
  Object refuseNonJson(String verb, List<NonJsonArgument> found);
}

/// The refusal for an atom without its own [NonJsonArgumentPolicy].
ArgumentError defaultNonJsonRefusal(
  String atomKey,
  String verb,
  List<NonJsonArgument> found,
) {
  final first = found.first;
  return ArgumentError(
    '$atomKey.$verb: argument ${first.where} is ${first.kind}, which JSON '
    'cannot carry',
  );
}

/// Result of an evaluate / evaluateAsync call, as returned by a platform
/// branch. Mirrors the subset of a JS engine's eval result callers consume.
class JsIsolateEvalResult {
  JsIsolateEvalResult({required this.stringResult, required this.isError});

  final String stringResult;
  final bool isError;
}

/// Builds the bootstrap installed into the JS engine.
///
/// [sendInvoke] is a JS expression evaluating to a function, called with the
/// payload JSON string to ship a `hostInvoke` message to the host. It is
/// parenthesised at the call site: a bare `function (p) {...}` in statement
/// position parses as a *declaration* and is rejected for having no name.
/// Everything else is identical across platforms.
String hostBridgeBootstrapJs(String sendInvoke) =>
    '''
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
  // Arguments cross as JSON. What JSON cannot carry is not silently turned
  // into null: it is listed with where it sat, and the host refuses the call.
  // `undefined` crosses as null, and an object property holding it is
  // omitted, as JSON.stringify does.
  globalThis.__hostJsonArgs = function(args) {
    var found = [];
    var open = [];
    function walk(v, path) {
      var t = typeof v;
      if (t === 'undefined') return null;
      if (t === 'function' || t === 'symbol' || t === 'bigint') {
        found.push({ path: path, kind: t });
        return null;
      }
      if (t === 'number' && !isFinite(v)) {
        found.push({ path: path, kind: String(v) });
        return null;
      }
      if (v === null || t !== 'object') return v;
      if (open.indexOf(v) >= 0) {
        found.push({ path: path, kind: 'cycle' });
        return null;
      }
      if (typeof v.toJSON === 'function') return walk(v.toJSON(), path);
      open.push(v);
      var out;
      if (Array.isArray(v)) {
        out = [];
        for (var i = 0; i < v.length; i++) out.push(walk(v[i], path.concat([i])));
      } else {
        out = {};
        for (var k in v) {
          if (!Object.prototype.hasOwnProperty.call(v, k)) continue;
          if (typeof v[k] === 'undefined') continue;
          out[k] = walk(v[k], path.concat([k]));
        }
      }
      open.pop();
      return out;
    }
    var clean = [];
    for (var j = 0; j < args.length; j++) clean.push(walk(args[j], [j]));
    return { args: clean, nonJson: found };
  };
  globalThis.__hostCall = function(atom, verb, args) {
    var uuid = '_h' + (++globalThis.__hostNextUuid);
    return new Promise(function(resolve, reject) {
      var prepared = globalThis.__hostJsonArgs(args || []);
      globalThis.__hostPending[uuid] = { resolve: resolve, reject: reject };
      ($sendInvoke)(
        JSON.stringify({
          uuid: uuid, atom: atom, verb: verb,
          args: prepared.args, nonJson: prepared.nonJson,
        }),
      );
    });
  };
})();
''';

/// Emits the `host.<key>.<verb>` surface for one atom.
String atomSurfaceJsLine(String key, List<String> verbs) {
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
