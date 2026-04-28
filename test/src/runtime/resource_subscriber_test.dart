import 'package:appplayer_core/src/exceptions.dart';
import 'package:appplayer_core/src/runtime/resource_subscriber.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

ReadResourceResult _result(String? text) => ReadResourceResult(contents: [
      ResourceContentInfo(uri: 'u', text: text),
    ]);

void main() {
  late MockClient client;
  late MockMCPUIRuntime runtime;
  late MockStateManager state;

  setUp(() {
    client = MockClient();
    runtime = MockMCPUIRuntime();
    state = MockStateManager();
    when(() => runtime.stateManager).thenReturn(state);
    when(() => state.set(any(), any())).thenReturn(null);
    when(() => runtime.registerResourceSubscription(any(), any()))
        .thenReturn(null);
    when(() => runtime.unregisterResourceSubscription(any()))
        .thenReturn(null);
  });

  group('ResourceSubscriber (MOD-RUNTIME-004)', () {
    test('TC-RES-001: subscribe with binding does everything', () async {
      when(() => client.subscribeResource('res://x'))
          .thenAnswer((_) async {});
      when(() => client.readResource('res://x'))
          .thenAnswer((_) async => _result('{"count":3}'));

      await ResourceSubscriber().subscribe(
        client: client,
        runtime: runtime,
        uri: 'res://x',
        binding: 'count',
      );

      verify(() => client.subscribeResource('res://x')).called(1);
      verify(() =>
              runtime.registerResourceSubscription('res://x', 'count'))
          .called(1);
      verify(() => state.set('count', 3)).called(1);
    });

    test('TC-RES-002: subscribe without binding skips register', () async {
      when(() => client.subscribeResource('res://x'))
          .thenAnswer((_) async {});
      when(() => client.readResource('res://x'))
          .thenAnswer((_) async => _result('{"a":1}'));

      await ResourceSubscriber().subscribe(
        client: client,
        runtime: runtime,
        uri: 'res://x',
      );
      verifyNever(() =>
          runtime.registerResourceSubscription(any(), any()));
      verify(() => state.set('a', 1)).called(1);
    });

    test('TC-RES-003: initial read failure is swallowed', () async {
      when(() => client.subscribeResource('res://x'))
          .thenAnswer((_) async {});
      when(() => client.readResource('res://x'))
          .thenThrow(StateError('io'));
      await ResourceSubscriber().subscribe(
        client: client,
        runtime: runtime,
        uri: 'res://x',
      );
      verifyNever(() => state.set(any(), any()));
    });

    test('TC-RES-005: subscribeResource failure throws', () async {
      when(() => client.subscribeResource('res://x'))
          .thenThrow(StateError('down'));
      await expectLater(
        ResourceSubscriber().subscribe(
          client: client,
          runtime: runtime,
          uri: 'res://x',
        ),
        throwsA(isA<ResourceSubscriptionException>()),
      );
    });

    test('TC-RES-006: unsubscribe', () async {
      when(() => client.unsubscribeResource('res://x'))
          .thenAnswer((_) async {});
      await ResourceSubscriber().unsubscribe(
        client: client,
        runtime: runtime,
        uri: 'res://x',
      );
      verify(() => client.unsubscribeResource('res://x')).called(1);
      verify(() => runtime.unregisterResourceSubscription('res://x'))
          .called(1);
    });

    test('TC-RES-007: unsubscribe failure throws', () async {
      when(() => client.unsubscribeResource('res://x'))
          .thenThrow(StateError('down'));
      await expectLater(
        ResourceSubscriber().unsubscribe(
          client: client,
          runtime: runtime,
          uri: 'res://x',
        ),
        throwsA(isA<ResourceSubscriptionException>()),
      );
    });
  });
}
