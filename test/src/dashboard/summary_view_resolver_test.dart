import 'package:appplayer_core/src/dashboard/summary_view_resolver.dart';
import 'package:appplayer_core/src/exceptions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

Resource _res(String uri, {String? name}) => Resource(
      uri: uri,
      name: name ?? uri,
      description: '',
      mimeType: 'application/json',
    );

ReadResourceResult _rr(String text) => ReadResourceResult(
      contents: [ResourceContentInfo(uri: 'u', text: text)],
    );

void main() {
  late MockClient client;
  late SummaryViewResolver resolver;

  setUp(() {
    client = MockClient();
    resolver = SummaryViewResolver();
  });

  group('SummaryViewResolver (MOD-DASH-004)', () {
    test('TC-SUMMARY-001: customUri takes precedence', () async {
      when(() => client.readResource('ui://my/summary'))
          .thenAnswer((_) async => _rr('{"a":1}'));
      final r =
          await resolver.fetch(client, customUri: 'ui://my/summary');
      expect(r['a'], 1);
      verifyNever(() => client.listResources());
    });

    test('TC-SUMMARY-002: ui://views/summary preferred', () async {
      when(() => client.listResources()).thenAnswer((_) async => [
            _res('ui://other'),
            _res('ui://views/summary'),
          ]);
      when(() => client.readResource('ui://views/summary'))
          .thenAnswer((_) async => _rr('{"ok":1}'));
      final r = await resolver.fetch(client);
      expect(r['ok'], 1);
    });

    test('TC-SUMMARY-003: URI keyword summary', () async {
      when(() => client.listResources()).thenAnswer((_) async => [
            _res('ui://home'),
            _res('ui://dashboard-summary-v2'),
          ]);
      when(() => client.readResource('ui://dashboard-summary-v2'))
          .thenAnswer((_) async => _rr('{"v":2}'));
      final r = await resolver.fetch(client);
      expect(r['v'], 2);
    });

    test('TC-SUMMARY-004: fallback summary from manifest', () async {
      when(() => client.listResources()).thenAnswer((_) async => [
            _res('ui://manifest', name: 'Manifest'),
          ]);
      when(() => client.readResource('ui://manifest')).thenAnswer((_) async =>
          _rr('{"id":"dev1","name":"Device 1"}'));
      final r = await resolver.fetch(client);
      expect(r['type'], 'page');
      expect(r['content']['children'][0]['value'], 'Device 1');
    });

    test('TC-SUMMARY-005: no resources at all', () async {
      when(() => client.listResources()).thenAnswer((_) async => []);
      await expectLater(
        resolver.fetch(client),
        throwsA(isA<ResourceNotFoundException>()),
      );
    });

    test('TC-SUMMARY-006: malformed JSON throws', () async {
      when(() => client.listResources())
          .thenAnswer((_) async => [_res('ui://views/summary')]);
      when(() => client.readResource('ui://views/summary'))
          .thenAnswer((_) async => _rr('not-json'));
      await expectLater(
        resolver.fetch(client),
        throwsA(isA<DefinitionParseException>()),
      );
    });
  });
}
