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
typedef HostAtomDispatcher =
    Future<Object?> Function(String atomKey, String verb, List<Object?> args);

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
  globalThis.__hostCall = function(atom, verb, args) {
    var uuid = '_h' + (++globalThis.__hostNextUuid);
    return new Promise(function(resolve, reject) {
      globalThis.__hostPending[uuid] = { resolve: resolve, reject: reject };
      ($sendInvoke)(
        JSON.stringify({ uuid: uuid, atom: atom, verb: verb, args: args || [] }),
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
