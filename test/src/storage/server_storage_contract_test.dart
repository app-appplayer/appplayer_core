import 'package:appplayer_core/src/model/server_config.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';

ServerConfig _s(String id) => ServerConfig(
      id: id,
      name: 'n-$id',
      description: 'd',
      transportType: TransportType.stdio,
      transportConfig: const {'command': 'dart'},
    );

void main() {
  group('ServerStorage contract via InMemoryServerStorage', () {
    late InMemoryServerStorage storage;

    setUp(() => storage = InMemoryServerStorage());

    test('TC-STOR-001: empty storage returns []', () async {
      expect(await storage.getServers(), isEmpty);
    });

    test('TC-STOR-002: saveServer inserts', () async {
      await storage.saveServer(_s('a'));
      expect((await storage.getServers()).map((e) => e.id), ['a']);
    });

    test('TC-STOR-003: saveServer upserts', () async {
      await storage.saveServer(_s('a'));
      await storage
          .saveServer(_s('a').copyWith(name: 'changed'));
      final list = await storage.getServers();
      expect(list, hasLength(1));
      expect(list.first.name, 'changed');
    });

    test('TC-STOR-004: deleteServer removes', () async {
      await storage.saveServer(_s('a'));
      await storage.deleteServer('a');
      expect(await storage.getServers(), isEmpty);
    });

    test('TC-STOR-005: deleteServer unknown is no-op', () async {
      await storage.deleteServer('nope');
      expect(await storage.getServers(), isEmpty);
    });

    test('TC-STOR-006: updateLastConnected', () async {
      await storage.saveServer(_s('a'));
      final t = DateTime.utc(2026, 4, 15);
      await storage.updateLastConnected('a', t);
      expect((await storage.getById('a'))!.lastConnectedAt, t);
    });

    test('TC-STOR-007: updateLastConnected unknown is no-op', () async {
      await storage.updateLastConnected('nope', DateTime.now());
      expect(await storage.getServers(), isEmpty);
    });

    test('TC-STOR-008: toggleFavorite', () async {
      await storage.saveServer(_s('a'));
      await storage.toggleFavorite('a');
      expect((await storage.getById('a'))!.isFavorite, isTrue);
      await storage.toggleFavorite('a');
      expect((await storage.getById('a'))!.isFavorite, isFalse);
    });

    test('TC-STOR-009: getById', () async {
      expect(await storage.getById('nope'), isNull);
      await storage.saveServer(_s('a'));
      expect((await storage.getById('a'))!.id, 'a');
    });
  });
}
