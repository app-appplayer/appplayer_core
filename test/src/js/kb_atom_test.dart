/// `host.kb` — what a js tool sees through the atom: the verbs and shapes the
/// kernel's store answers, key rules refused with their code, conflicts
/// returned as results, and one app kept out of another's state.
library;

import 'package:appplayer_core/src/js/atoms/kb_atom.dart';
import 'package:appplayer_core/src/js/js_bridge_protocol.dart' show NonJsonArgument;
import 'package:brain_kernel/brain_kernel.dart'
    show BundleKbStore, InMemoryKvStoragePort, KbError, KvKbRecordStore;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late KvKbRecordStore records;
  late KbAtom notes;

  setUp(() {
    records = KvKbRecordStore(InMemoryKvStoragePort());
    notes = KbAtom(BundleKbStore(appId: 'bundle:works.notes', records: records));
  });

  test('verbs and return shapes', () async {
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
    expect(await notes.dispatch('conflicts', const []), isEmpty);
  });

  test('a stale write comes back as a conflict with the current value; force overwrites',
      () async {
    final otherDevice =
        KbAtom(BundleKbStore(appId: 'bundle:works.notes', records: records));
    await notes.dispatch('put', ['doc', 'v1']);
    await otherDevice.dispatch('get', ['doc']);
    await notes.dispatch('put', ['doc', 'v2']);

    expect(await otherDevice.dispatch('put', ['doc', 'mine']), {
      'ok': false,
      'conflict': {'value': 'v2'},
    });
    expect(
      await otherDevice.dispatch('put', [
        'doc',
        'mine',
        {'force': true},
      ]),
      {'ok': true},
    );
    expect(await notes.dispatch('get', ['doc']), 'mine');
  });

  test('one app cannot read or overwrite another app\'s state', () async {
    final kanban =
        KbAtom(BundleKbStore(appId: 'listing:kanban', records: records));
    await notes.dispatch('put', ['shared-name', 'notes']);
    await kanban.dispatch('put', ['shared-name', 'kanban']);

    expect(await notes.dispatch('get', ['shared-name']), 'notes');
    expect(await kanban.dispatch('get', ['shared-name']), 'kanban');
    expect(await kanban.dispatch('list', const []), hasLength(1));
  });

  test('query without a knowledge engine refuses by name', () async {
    await expectLater(
      notes.dispatch('query', ['anything']),
      throwsA(isA<KbError>()
          .having((e) => e.code, 'code', KbError.queryUnavailable)),
    );
  });

  test('an argument JSON cannot carry: the key position is a key error, '
      'anything else a value error', () {
    expect(
      notes.refuseNonJson('get', const [NonJsonArgument([0], 'function')]),
      isA<KbError>().having((e) => e.code, 'code', KbError.invalidKey),
    );
    final value = notes.refuseNonJson('put', const [
      NonJsonArgument([1, 'items', 0], 'NaN'),
    ]);
    expect(value, isA<KbError>().having((e) => e.code, 'code', KbError.invalidValue));
    expect('$value', contains('1.items.0 is NaN'));
  });

  test('bad keys and arguments are refused, nothing stored', () async {
    for (final bad in <Object?>['', 42, 'a/../b', '/lead']) {
      await expectLater(notes.dispatch('get', [bad]),
          throwsA(isA<KbError>().having((e) => e.code, 'code', KbError.invalidKey)));
    }
    await expectLater(notes.dispatch('put', ['only-key']),
        throwsA(isA<KbError>()));
    expect(await notes.dispatch('list', const []), isEmpty);
  });
}
