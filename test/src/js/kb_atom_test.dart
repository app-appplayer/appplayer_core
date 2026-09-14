/// `host.kb` — the verbs and return shapes a js tool relies on, and the
/// per-bundle isolation that keeps one bundle out of another's state.
library;

import 'package:appplayer_core/appplayer_core.dart'
    show DomainEntry, DomainStorage;
import 'package:appplayer_core/src/js/atoms/kb_atom.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryDomainStorage implements DomainStorage {
  final Map<String, Map<String, Object?>> _byNamespace = {};

  Map<String, Object?> _ns(String n) => _byNamespace.putIfAbsent(n, () => {});

  @override
  Future<void> put(String namespace, String key, Object? value) async =>
      _ns(namespace)[key] = value;

  @override
  Future<Object?> get(String namespace, String key) async => _ns(namespace)[key];

  @override
  Future<List<DomainEntry>> list(String namespace, {String prefix = ''}) async =>
      [
        for (final e in _ns(namespace).entries)
          if (e.key.startsWith(prefix)) DomainEntry(key: e.key, value: e.value),
      ];

  @override
  Future<bool> delete(String namespace, String key) async {
    final ns = _ns(namespace);
    final had = ns.containsKey(key);
    ns.remove(key);
    return had;
  }

  @override
  Future<void> clearNamespace(String namespace) async =>
      _byNamespace.remove(namespace);
}

void main() {
  late _MemoryDomainStorage storage;
  late KbAtom notes;

  setUp(() {
    storage = _MemoryDomainStorage();
    notes = KbAtom(storage: storage, namespace: 'works.notes');
  });

  test('verbs and return shapes match the reference host', () async {
    expect(await notes.dispatch('get', ['missing']), isNull);
    expect(await notes.dispatch('put', ['a', {'n': 1}]), {'ok': true});
    expect(await notes.dispatch('get', ['a']), {'n': 1});
    await notes.dispatch('put', ['ab', 2]);
    await notes.dispatch('put', ['b', 3]);
    expect(await notes.dispatch('list', ['a']), [
      {'key': 'a', 'value': {'n': 1}},
      {'key': 'ab', 'value': 2},
    ]);
    expect(await notes.dispatch('delete', ['a']), {'removed': true});
    expect(await notes.dispatch('delete', ['a']), {'removed': false});
  });

  test('one bundle cannot read or overwrite another bundle\'s state', () async {
    final kanban = KbAtom(storage: storage, namespace: 'works.kanban');
    await notes.dispatch('put', ['shared-name', 'notes']);
    await kanban.dispatch('put', ['shared-name', 'kanban']);

    expect(await notes.dispatch('get', ['shared-name']), 'notes');
    expect(await kanban.dispatch('get', ['shared-name']), 'kanban');
    expect(await kanban.dispatch('list', const []), hasLength(1));
  });

  test('query without a knowledge engine refuses by name', () async {
    await expectLater(
      notes.dispatch('query', ['anything']),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('kb.query is not available'))),
    );
  });

  test('bad arguments are refused, not stored under a junk key', () async {
    await expectLater(notes.dispatch('put', ['only-key']), throwsArgumentError);
    await expectLater(notes.dispatch('get', ['']), throwsArgumentError);
    await expectLater(notes.dispatch('get', [42]), throwsArgumentError);
    expect(await notes.dispatch('list', const []), isEmpty);
  });
}
