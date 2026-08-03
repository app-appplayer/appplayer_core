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

    test(
        'TC-APPLOAD-010: pageLoader applies the transform to every page it '
        'reads', () async {
      // mcp_ui_dsl §6.12.7 — a host applies one resolution placement to every
      // document. The server-open path passes the served bundle\'s
      // `bundle://` resolver here; without it the entry document resolved and
      // pages loaded afterwards did not, so the first frame drew and the
      // second showed nothing.
      when(() => client.readResource('ui://pages/home')).thenAnswer(
        (_) async => _readResult('{"type":"page","src":"bundle://logo.png"}'),
      );
      final load = loader.pageLoaderFor(
        client,
        transform: (page) => <String, dynamic>{
          ...page,
          'src': 'data:image/png;base64,AAAA',
        },
      );

      final page = await load('ui://pages/home');
      expect(page['src'], 'data:image/png;base64,AAAA');
      expect(page['type'], 'page', reason: 'the rest of the page is untouched');
    });

    test(
        'TC-APPLOAD-011: the cached entry page gets the transform too',
        () async {
      // The server-open path feeds the already-read entry document back
      // through a cache so the first frame never re-reads a possibly dead
      // link. That cached copy is raw off the wire, so it needs the same
      // treatment as the live path — otherwise the one page guaranteed to
      // render is the one page that does not resolve.
      final cached = <String, dynamic>{
        'type': 'page',
        'src': 'bundle://logo.png',
      };
      final load = loader.cachingPageLoaderFor(
        client,
        {'ui://app': cached},
        transform: (page) => <String, dynamic>{
          ...page,
          'src': 'data:image/png;base64,AAAA',
        },
      );

      final page = await load('ui://app');
      expect(page['src'], 'data:image/png;base64,AAAA');
      verifyNever(() => client.readResource('ui://app'));
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

    test('TC-APPLOAD-012: bare page is promoted to a single-route '
        'application pointing at appUri, lifting the page title', () {
      final wrapped = loader.wrapAsApplication(
        const {
          'type': 'page',
          'title': 'ESP32 BLE MCP Node',
          'content': {'type': 'column', 'children': []},
        },
        appUri: 'ui://app',
      );
      expect(wrapped['type'], 'application');
      // Title is carried from the page so a board that serves no
      // ui://app/info metadata still names the app from its own structure.
      expect(wrapped['title'], 'ESP32 BLE MCP Node');
      expect(wrapped['routes'], {'/': 'ui://app'});
      expect(wrapped['initialRoute'], '/');
    });

    test('TC-APPLOAD-013: an untyped single UI is also promoted', () {
      final wrapped = loader.wrapAsApplication(
        const {'content': {'type': 'text', 'value': 'hi'}},
        appUri: 'ui://app',
      );
      expect(wrapped['type'], 'application');
      expect(wrapped['routes'], {'/': 'ui://app'});
      // No page title → no application title key (runtime supplies a default).
      expect(wrapped.containsKey('title'), isFalse);
    });

    test('TC-APPLOAD-015: cachingPageLoaderFor serves the cached page from '
        'memory without touching the client', () async {
      final fn = loader.cachingPageLoaderFor(client, {
        'ui://app': const {'type': 'page', 'title': 'Board'},
      });
      final page = await fn('ui://app');
      expect(page['title'], 'Board');
      // The initial page must render without a second read over the link.
      verifyNever(() => client.readResource('ui://app'));
    });

    test('TC-APPLOAD-016: cachingPageLoaderFor falls back to the client for '
        'an uncached uri', () async {
      when(() => client.readResource('ui://other'))
          .thenAnswer((_) async => _readResult('{"type":"page"}'));
      final fn = loader.cachingPageLoaderFor(client, {
        'ui://app': const {'type': 'page'},
      });
      final page = await fn('ui://other');
      expect(page['type'], 'page');
      verify(() => client.readResource('ui://other')).called(1);
    });

    test('TC-APPLOAD-014: an application document passes through unchanged',
        () {
      const appDef = {
        'type': 'application',
        'title': 'Already An App',
        'routes': {'/': 'ui://home', '/settings': 'ui://settings'},
      };
      final wrapped = loader.wrapAsApplication(appDef, appUri: 'ui://home');
      expect(identical(wrapped, appDef), isTrue);
    });
  });
}
