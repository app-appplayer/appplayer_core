/// Abstract base for one host atom category. Each implementation owns
/// one `host.<key>` namespace exposed to bundle JS tools through the
/// `JsHostBridge`. Verbs declared on the atom become methods on the JS
/// object — `host.mcp.callTool(name, args)` resolves to
/// `McpAtom.dispatch('callTool', [name, args])`.
///
/// Atoms are host-curated capability buckets, distinct from mcp_bundle's
/// 50+ Port hub (which targets Dart consumers). Host (Standard / Pro /
/// X / Custom) decides which atoms to expose — the bundle's
/// `requires.builtinAtoms` declares the set it needs and the host
/// rejects activation if any required atom is missing.
library;

/// One verb declared by an [AtomCategory]. The bridge turns each verb
/// into a JS function on the atom's `host.<key>` object.
class AtomVerb {
  const AtomVerb(this.name, {this.description});

  /// JS function name. Becomes `host.<atomKey>.<name>`.
  final String name;

  /// Optional human-readable description for diagnostic / docs.
  final String? description;
}

abstract class AtomCategory {
  /// Atom key — the namespace under `host.*`. Stable identifier the
  /// manifest uses in `requires.builtinAtoms`.
  String get key;

  /// Verbs exposed to JS. The bridge installs one JS function per verb
  /// on `host.<key>`. Empty list = no methods (the atom registers but
  /// JS calls always fail).
  List<AtomVerb> get verbs;

  /// Dispatch a verb invocation. Returns any JSON-serialisable value
  /// (or a Future thereof) — the bridge JSON-encodes and hands back to
  /// the JS Promise. Throw to reject the promise.
  ///
  /// `args` is the list passed by JS (`host.fs.read(path)` → `[path]`).
  /// Atoms validate arity / types and throw [ArgumentError] for schema
  /// violations so the JS caller gets a clean error message.
  Future<Object?> dispatch(String verb, List<Object?> args);
}
