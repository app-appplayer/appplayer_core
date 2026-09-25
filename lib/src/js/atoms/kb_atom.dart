/// `host.kb.*` atom — forwards to the kernel's [BundleKbStore].
///
/// The contract (verbs, return shapes, key rules, versions and conflicts)
/// lives in one implementation every host runs. This atom only unpacks js
/// arguments, so it cannot answer differently from another host's.
///
///   * `get(key)` → value | `null`
///   * `put(key, value, [{force}])` → `{ok: true}` | `{ok: false, conflict: {value}}`
///   * `list([prefix])` → `[{key, value}]`, ascending by key
///   * `delete(key, [{force}])` → `{removed: bool}` | `{ok: false, conflict: {value}}`
///   * `conflicts()` → `[{key, mine, theirs}]`
///   * `query(text, [{topK, namespace, sourceId}])` → hits
library;

import 'package:brain_kernel/brain_kernel.dart' show BundleKbStore, KbError;

import '../atom_category.dart';
import '../js_bridge_protocol.dart' show NonJsonArgument, NonJsonArgumentPolicy;

class KbAtom extends AtomCategory implements NonJsonArgumentPolicy {
  KbAtom(this.store);

  /// A key JSON cannot carry is not a key; anything else it cannot carry is
  /// not a value. Nothing is stored either way.
  @override
  Object refuseNonJson(String verb, List<NonJsonArgument> found) {
    final first = found.first;
    final keyArgument = verb != 'conflicts' && first.argumentIndex == 0;
    return KbError(
      keyArgument ? KbError.invalidKey : KbError.invalidValue,
      'kb.$verb: ${first.where} is ${first.kind}, which JSON cannot carry',
    );
  }

  /// This bundle's state, keyed by its app identity.
  final BundleKbStore store;

  @override
  String get key => 'kb';

  @override
  List<AtomVerb> get verbs => const [
        AtomVerb('get',
            description: "Read this app's value. (key) → value | null."),
        AtomVerb('put',
            description: 'Write on the version last read. (key, value, '
                '[{force}]) → {ok: true} | {ok: false, conflict: {value}}.'),
        AtomVerb('list',
            description: "This app's entries. ([prefix]) → [{key, value}]."),
        AtomVerb('delete',
            description: 'Remove on the version last read. (key, [{force}]) '
                '→ {removed} | {ok: false, conflict: {value}}.'),
        AtomVerb('conflicts',
            description: 'Offline writes rejected on reconnect. () → '
                '[{key, mine, theirs}].'),
        AtomVerb('query',
            description: 'Knowledge query. (text, [{topK, namespace, '
                'sourceId}]) → hits.'),
      ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    Object? arg(int i) => i < args.length ? args[i] : null;
    bool force(int i) {
      final opts = arg(i);
      return opts is Map && opts['force'] == true;
    }

    switch (verb) {
      case 'get':
        return store.get(_key(arg(0)));
      case 'put':
        if (args.length < 2) {
          throw const KbError(KbError.invalidValue, 'put requires (key, value)');
        }
        return store.put(_key(arg(0)), arg(1), force: force(2));
      case 'list':
        final prefix = arg(0);
        return store.list(prefix is String ? prefix : '');
      case 'delete':
        return store.delete(_key(arg(0)), force: force(1));
      case 'conflicts':
        return store.conflicts();
      case 'query':
        final text = arg(0);
        if (text is! String) {
          throw ArgumentError('query requires (text, [opts])');
        }
        final opts = arg(1) is Map ? arg(1) as Map : const <String, Object?>{};
        return store.query(
          text,
          topK: (opts['topK'] as num?)?.toInt() ?? 5,
          namespace: opts['namespace'] as String?,
          sourceId: opts['sourceId'] as String?,
        );
      default:
        throw ArgumentError('unknown verb: kb.$verb');
    }
  }

  static String _key(Object? raw) {
    BundleKbStore.checkKey(raw);
    return raw! as String;
  }
}
