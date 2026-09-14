/// `host.kb.*` atom — a bundle's durable key/value state, and knowledge query
/// where the host has a knowledge engine (bundle spec §4.8.1).
///
/// Same verbs and the same return shapes as the reference Studio host, so a
/// js tool written against one reads the same on the other:
///
///   * `get(key)` → value | `null`
///   * `put(key, value)` → `{ok: true}`
///   * `list(prefix?)` → `[{key, value}]`
///   * `delete(key)` → `{removed: bool}`
///   * `query(text, {topK?, namespace?, sourceId?})` → hits
///
/// Storage is **isolated per bundle** — every key is pinned to the bundle's
/// `manifest.id`, and the js caller never names a namespace, so one bundle
/// cannot read or overwrite another's state.
library;

import 'package:brain_kernel/brain_kernel.dart'
    show DomainStorage, KnowledgeQueryEngine;

import '../atom_category.dart';

class KbAtom extends AtomCategory {
  KbAtom({
    required this.storage,
    required this.namespace,
    this.engine,
  });

  /// Per-bundle durable state.
  final DomainStorage storage;

  /// The bundle's `manifest.id`; every get/put/list/delete is pinned to it.
  final String namespace;

  /// Knowledge query. Absent where the host booted no knowledge engine, and
  /// then `query` refuses by name rather than answering an empty list that
  /// reads like "nothing matched".
  final KnowledgeQueryEngine? engine;

  @override
  String get key => 'kb';

  @override
  List<AtomVerb> get verbs => const [
        AtomVerb('get',
            description: 'Read from this bundle\'s state. (key) → value | null.'),
        AtomVerb('put',
            description: 'Write to this bundle\'s state. (key, value) → {ok}.'),
        AtomVerb('list',
            description: 'Entries in this bundle\'s state. ([prefix]) → '
                '[{key, value}].'),
        AtomVerb('delete',
            description: 'Remove an entry. (key) → {removed: bool}.'),
        AtomVerb('query',
            description: 'Knowledge query. (text, [{topK, namespace, '
                'sourceId}]) → hits.'),
      ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'get':
        if (args.isEmpty) throw ArgumentError('get requires (key)');
        return storage.get(namespace, _key(args[0]));
      case 'put':
        if (args.length < 2) throw ArgumentError('put requires (key, value)');
        await storage.put(namespace, _key(args[0]), args[1]);
        return const <String, dynamic>{'ok': true};
      case 'list':
        final prefix =
            args.isNotEmpty && args[0] is String ? args[0] as String : '';
        final entries = await storage.list(namespace, prefix: prefix);
        return <Map<String, dynamic>>[
          for (final e in entries)
            <String, dynamic>{'key': e.key, 'value': e.value},
        ];
      case 'delete':
        if (args.isEmpty) throw ArgumentError('delete requires (key)');
        final removed = await storage.delete(namespace, _key(args[0]));
        return <String, dynamic>{'removed': removed};
      case 'query':
        final engine = this.engine;
        if (engine == null) {
          throw StateError('kb.query is not available in this host: '
              'no knowledge engine is running');
        }
        if (args.isEmpty || args[0] is! String) {
          throw ArgumentError('query requires (text, [opts])');
        }
        final opts = args.length > 1 && args[1] is Map
            ? args[1] as Map
            : const <String, dynamic>{};
        final hits = await engine.query(
          args[0] as String,
          topK: (opts['topK'] as num?)?.toInt() ?? 5,
          namespace: opts['namespace'] as String?,
          sourceId: opts['sourceId'] as String?,
        );
        return <Map<String, dynamic>>[for (final h in hits) h.toJson()];
      default:
        throw ArgumentError('unknown verb: kb.$verb');
    }
  }

  static String _key(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      throw ArgumentError('key must be a non-empty String');
    }
    return raw;
  }
}
