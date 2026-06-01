import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InMemorySettingsStore', () {
    late InMemorySettingsStore store;

    setUp(() {
      store = InMemorySettingsStore();
    });

    test('readAll returns empty map for unknown bundle', () async {
      expect(await store.readAll('missing'), <String, dynamic>{});
    });

    test('writeAll then readAll round-trips values', () async {
      await store.writeAll('b1', <String, dynamic>{'k': 1, 's': 'hi'});
      expect(await store.readAll('b1'),
          <String, dynamic>{'k': 1, 's': 'hi'});
    });

    test('writeAll snapshots the input — later caller mutations do not leak',
        () async {
      final input = <String, dynamic>{'k': 1};
      await store.writeAll('b1', input);
      input['k'] = 999;
      expect(await store.readAll('b1'), <String, dynamic>{'k': 1});
    });

    test('readAll snapshots stored values — caller mutations do not leak',
        () async {
      await store.writeAll('b1', <String, dynamic>{'k': 1});
      final out = await store.readAll('b1');
      out['k'] = 999;
      expect(await store.readAll('b1'), <String, dynamic>{'k': 1});
    });

    test('read returns null for unwritten field', () async {
      expect(await store.read('b1', 'unset'), isNull);
      await store.writeAll('b1', <String, dynamic>{'other': 1});
      expect(await store.read('b1', 'unset'), isNull);
    });

    test('read returns stored value', () async {
      await store.writeAll('b1', <String, dynamic>{'k': 42});
      expect(await store.read('b1', 'k'), 42);
    });

    test('write into unknown bundle creates the slot', () async {
      await store.write('b1', 'k', 7);
      expect(await store.read('b1', 'k'), 7);
      expect(await store.readAll('b1'), <String, dynamic>{'k': 7});
    });

    test('write overwrites existing field without dropping siblings',
        () async {
      await store.writeAll('b1', <String, dynamic>{'a': 1, 'b': 2});
      await store.write('b1', 'b', 99);
      expect(await store.readAll('b1'),
          <String, dynamic>{'a': 1, 'b': 99});
    });

    test('writing null stores the null value', () async {
      await store.write('b1', 'k', null);
      expect(await store.read('b1', 'k'), isNull);
      expect((await store.readAll('b1')).containsKey('k'), isTrue);
    });

    test('clear removes every value for the bundle only', () async {
      await store.writeAll('b1', <String, dynamic>{'a': 1});
      await store.writeAll('b2', <String, dynamic>{'b': 2});
      await store.clear('b1');
      expect(await store.readAll('b1'), <String, dynamic>{});
      expect(await store.readAll('b2'), <String, dynamic>{'b': 2});
    });

    test('clear on unknown bundle is a no-op', () async {
      await store.clear('never-written');
      expect(await store.readAll('never-written'), <String, dynamic>{});
    });

    test('bundles are isolated', () async {
      await store.write('b1', 'k', 1);
      await store.write('b2', 'k', 2);
      expect(await store.read('b1', 'k'), 1);
      expect(await store.read('b2', 'k'), 2);
    });
  });
}
