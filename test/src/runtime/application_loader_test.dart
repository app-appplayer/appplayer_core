import 'package:appplayer_core/src/exceptions.dart';
import 'package:appplayer_core/src/runtime/application_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

Resource _res(String uri, {String? name}) =>
    Resource(uri: uri, name: name ?? uri, description: '', mimeType: 'text/plain');

ReadResourceResult _readResult(String text) => ReadResourceResult(
      contents: [
        ResourceContentInfo(uri: 'u', mimeType: 'application/json', text: text),
      ],
    );

void main() {
  group('ApplicationLoader (MOD-RUNTIME-002)', () {
    late MockClient client;
    late ApplicationLoader loader;

    setUp(() {
      client = MockClient();
      loader = ApplicationLoader();
    });

    test('TC-APPLOAD-001: ui://app selected', () async {
      when(() => client.listResources())
          .thenAnswer((_) async => [_res('ui://app', name: 'App')]);
      when(() => client.readResource('ui://app'))
          .thenAnswer((_) async => _readResult('{"k":1}'));
      final def = await loader.load(client);
      expect(def['k'], 1);
    });

    test('TC-APPLOAD-002: /app suffix', () async {
      when(() => client.listResources())
          .thenAnswer((_) async => [_res('custom://x/app', name: 'foo')]);
      when(() => client.readResource('custom://x/app'))
          .thenAnswer((_) async => _readResult('{}'));
      await loader.load(client);
      verify(() => client.readResource('custom://x/app')).called(1);
    });

    test('TC-APPLOAD-003/004: name contains app / main', () async {
      when(() => client.listResources())
          .thenAnswer((_) async => [_res('ui://home', name: 'mainApp')]);
      when(() => client.readResource('ui://home'))
          .thenAnswer((_) async => _readResult('{}'));
      await loader.load(client);
      verify(() => client.readResource('ui://home')).called(1);
    });

    test('TC-APPLOAD-005: ui:// prefix fallback', () async {
      when(() => client.listResources()).thenAnswer((_) async => [
            _res('file://x', name: 'noise'),
            _res('ui://first', name: 'first'),
          ]);
      when(() => client.readResource('ui://first'))
          .thenAnswer((_) async => _readResult('{}'));
      await loader.load(client);
      verify(() => client.readResource('ui://first')).called(1);
    });

    test('TC-APPLOAD-006: first resource fallback', () async {
      when(() => client.listResources()).thenAnswer(
          (_) async => [_res('file://x', name: 'noise')]);
      when(() => client.readResource('file://x'))
          .thenAnswer((_) async => _readResult('{}'));
      await loader.load(client);
      verify(() => client.readResource('file://x')).called(1);
    });

    test('TC-APPLOAD-007: empty list throws', () async {
      when(() => client.listResources()).thenAnswer((_) async => []);
      await expectLater(
        loader.load(client),
        throwsA(isA<ResourceNotFoundException>()),
      );
    });

    test('TC-APPLOAD-008/009: parse errors', () async {
      when(() => client.listResources())
          .thenAnswer((_) async => [_res('ui://app', name: 'App')]);

      // text null
      when(() => client.readResource('ui://app')).thenAnswer((_) async =>
          ReadResourceResult(contents: [
            ResourceContentInfo(uri: 'u', mimeType: 't', text: null),
          ]));
      await expectLater(
        loader.load(client),
        throwsA(isA<DefinitionParseException>()),
      );

      // invalid json
      when(() => client.readResource('ui://app'))
          .thenAnswer((_) async => _readResult('not-json'));
      await expectLater(
        loader.load(client),
        throwsA(isA<DefinitionParseException>()),
      );
    });

    test('TC-APPLOAD-010: pageLoaderFor returns parsed JSON', () async {
      when(() => client.readResource('ui://page/1'))
          .thenAnswer((_) async => _readResult('{"page":"x"}'));
      final fn = loader.pageLoaderFor(client);
      final page = await fn('ui://page/1');
      expect(page['page'], 'x');
    });

    test('TC-APPLOAD-011: pageLoaderFor text null → {}', () async {
      when(() => client.readResource('ui://page/2')).thenAnswer((_) async =>
          ReadResourceResult(contents: [
            ResourceContentInfo(uri: 'u', mimeType: 't', text: null),
          ]));
      final fn = loader.pageLoaderFor(client);
      final page = await fn('ui://page/2');
      expect(page, isEmpty);
    });
  });
}
