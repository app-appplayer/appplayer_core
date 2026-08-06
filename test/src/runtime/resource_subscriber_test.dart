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

  /// Reconnect. A subscription belongs to the CONNECTION: after a background
  /// round trip the link is torn down and rebuilt and the server has no
  /// memory of what the old link subscribed. The runtime bindings survive in
  /// the runtime, so nothing on screen looked wrong — the stream just stopped,
  /// and pressing Subscribe again did nothing because the binding was already
  /// registered. Only the wire call has to be redone, on the NEW client.
  group('reattach after a reconnect', () {
    test('re-issues the wire subscribe on the new client', () async {
      when(() => client.subscribeResource('data://uptime'))
          .thenAnswer((_) async {});
      when(() => client.readResource('data://uptime'))
          .thenAnswer((_) async => _result('{"uptime":1}'));

      final subscriber = ResourceSubscriber();
      await subscriber.subscribe(
        client: client,
        runtime: runtime,
        uri: 'data://uptime',
        binding: 'uptime',
        ownerKey: 'srv-1',
      );

      // Only what the RECONNECT does is under test from here.
      clearInteractions(runtime);
      clearInteractions(state);

      // The reconnect: a different Client object with no memory of the old
      // subscription — which is exactly what the server sees too.
      final fresh = MockClient();
      when(() => fresh.subscribeResource('data://uptime'))
          .thenAnswer((_) async {});
      when(() => fresh.readResource('data://uptime'))
          .thenAnswer((_) async => _result('{"uptime":42}'));

      await subscriber.reattach(
        client: fresh,
        runtime: runtime,
        ownerKey: 'srv-1',
      );

      verify(() => fresh.subscribeResource('data://uptime')).called(1);
      verify(() => state.set('uptime', 42)).called(1);
      verifyNever(() => runtime.registerResourceSubscription(any(), any()));
      // The binding was never lost, so re-registering it would be the wrong
      // repair — and would have hidden that the wire call was the gap.
    });

    test('an owner with nothing subscribed does not touch the wire', () async {
      final fresh = MockClient();
      await ResourceSubscriber().reattach(
        client: fresh,
        runtime: runtime,
        ownerKey: 'srv-unknown',
      );
      verifyNever(() => fresh.subscribeResource(any()));
    });

    test('one failing resource does not stop the rest', () async {
      when(() => client.subscribeResource(any())).thenAnswer((_) async {});
      when(() => client.readResource(any()))
          .thenAnswer((_) async => _result('{"a":1}'));

      final subscriber = ResourceSubscriber();
      for (final uri in <String>['data://a', 'data://b']) {
        await subscriber.subscribe(
          client: client,
          runtime: runtime,
          uri: uri,
          binding: uri,
          ownerKey: 'srv-1',
        );
      }

      final fresh = MockClient();
      when(() => fresh.subscribeResource('data://a'))
          .thenThrow(StateError('refused'));
      when(() => fresh.subscribeResource('data://b'))
          .thenAnswer((_) async {});
      when(() => fresh.readResource(any()))
          .thenAnswer((_) async => _result('{"b":2}'));

      final result = await subscriber.reattach(
        client: fresh,
        runtime: runtime,
        ownerKey: 'srv-1',
      );

      verify(() => fresh.subscribeResource('data://b')).called(1);
      verify(() => state.set('b', 2)).called(1);
      // Attempts and successes are different numbers. Reporting the attempt
      // count is what made a fully-refused reattach read as a successful one.
      expect(result.resubscribed, 1);
      expect(result.failed, 1);
      expect(result.isTotalFailure, isFalse);
    });

    test('a reattach where everything is refused says so', () async {
      when(() => client.subscribeResource(any())).thenAnswer((_) async {});
      when(() => client.readResource(any()))
          .thenAnswer((_) async => _result('{"a":1}'));

      final subscriber = ResourceSubscriber();
      for (final uri in <String>['data://a', 'data://b']) {
        await subscriber.subscribe(
          client: client,
          runtime: runtime,
          uri: uri,
          binding: uri,
          ownerKey: 'srv-1',
        );
      }

      final fresh = MockClient();
      when(() => fresh.subscribeResource(any()))
          .thenThrow(StateError('refused'));

      final result = await subscriber.reattach(
        client: fresh,
        runtime: runtime,
        ownerKey: 'srv-1',
      );

      // The connection is up and every stream is dead — the case that was
      // indistinguishable from success in the log.
      expect(result.resubscribed, 0);
      expect(result.failed, 2);
      expect(result.isTotalFailure, isTrue);
    });

    test('nothing to reattach is not a failure', () async {
      final result = await ResourceSubscriber().reattach(
        client: MockClient(),
        runtime: runtime,
        ownerKey: 'srv-unknown',
      );
      expect(result.resubscribed, 0);
      expect(result.failed, 0);
      expect(result.isTotalFailure, isFalse);
    });
  });
}
