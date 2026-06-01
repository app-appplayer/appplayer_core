/// Owner-side handle for a per-bundle JavaScript runtime. The
/// underlying flutter_js engine + host-bridge plumbing live inside a
/// dedicated Dart `Isolate` ([JsToolIsolate]) so the static
/// `_sendMessageDartFunc` field in flutter_js 0.8.7 JSCore
/// (jscore_runtime.dart:171) — which would otherwise be stomped by
/// every new runtime constructor and break previously-attached
/// bridges — stays scoped per isolate.
///
/// API surface mirrors the pre-isolate version so call sites
/// (`host_bundle_activation._registerJsTool`, friends) keep working
/// after the refactor. `evaluate` / `evaluateAsync` are async because
/// every call ships a message to the worker and awaits the reply.
library;

import 'dart:async';

import 'js_tool_isolate.dart';
import 'atom_category.dart';

/// Result of an evaluate / evaluateAsync call — wraps the
/// JSON-serialized return value from the worker. Mirrors the subset
/// of `flutter_js.JsEvalResult` callers actually consume.
class JsEvalResult {
  JsEvalResult({required this.stringResult, required this.isError});
  final String stringResult;
  final bool isError;
}

class JsToolRuntime {
  JsToolRuntime();

  JsToolIsolate? _isolate;
  bool _disposed = false;
  Future<JsToolIsolate>? _isolateFuture;

  bool get isDisposed => _disposed;

  /// Spawn the isolate (or return the already-spawned one). Idempotent
  /// — re-entry while spawn is in flight reuses the same future.
  Future<JsToolIsolate> _ensureIsolate() {
    if (_disposed) {
      throw StateError('JsToolRuntime disposed');
    }
    final existing = _isolate;
    if (existing != null) return Future<JsToolIsolate>.value(existing);
    return _isolateFuture ??= () async {
      final spawned = await JsToolIsolate.spawn();
      _isolate = spawned;
      return spawned;
    }();
  }

  /// Attach the host bridge. Atoms allowed by [allowedAtoms] are
  /// surfaced inside the worker's `host.*`. The [atoms] list provides
  /// the verb names + the live atom instances the dispatcher will
  /// invoke.
  Future<void> attachHostBridge({
    required Iterable<AtomCategory> atoms,
    required Iterable<String> allowedAtoms,
  }) async {
    final iso = await _ensureIsolate();
    final byKey = <String, AtomCategory>{
      for (final a in atoms) a.key: a,
    };
    await iso.attachHostBridge(
      atoms: atoms,
      allowedAtoms: allowedAtoms,
      dispatch: (atomKey, verb, args) async {
        final atom = byKey[atomKey];
        if (atom == null) {
          throw ArgumentError('atom "$atomKey" not exposed to bundle');
        }
        return atom.dispatch(verb, args);
      },
    );
  }

  Future<JsEvalResult> evaluate(String code, {String? sourceUrl}) async {
    final iso = await _ensureIsolate();
    final r = await iso.evaluate(code, sourceUrl: sourceUrl);
    return JsEvalResult(
        stringResult: r.stringResult, isError: r.isError);
  }

  Future<JsEvalResult> evaluateAsync(String code,
      {String? sourceUrl}) async {
    final iso = await _ensureIsolate();
    final r = await iso.evaluateAsync(code, sourceUrl: sourceUrl);
    return JsEvalResult(
        stringResult: r.stringResult, isError: r.isError);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final iso = _isolate;
    _isolate = null;
    if (iso != null) await iso.dispose();
  }
}
