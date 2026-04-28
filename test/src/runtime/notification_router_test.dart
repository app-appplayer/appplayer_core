import 'package:appplayer_core/src/runtime/notification_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

void main() {
  late MockClient client;
  late MockMCPUIRuntime runtime;

  setUp(() {
    client = MockClient();
    runtime = MockMCPUIRuntime();
  });

  group('NotificationRouter (MOD-RUNTIME-005)', () {
    test('TC-NOTIF-001: registers handler on correct method', () {
      when(() => client.onNotification(any(), any())).thenReturn(null);

      NotificationRouter().register(client: client, runtime: runtime);

      verify(() => client.onNotification(
            'notifications/resources/updated',
            any(),
          )).called(1);
    });

    test('TC-NOTIF-002/003: routes to handleNotification only when initialized',
        () async {
      Function(Map<String, dynamic>)? captured;
      when(() => client.onNotification(any(), any())).thenAnswer((inv) {
        captured = inv.positionalArguments[1] as Function(Map<String, dynamic>);
      });
      when(() => runtime.isInitialized).thenReturn(false);

      NotificationRouter().register(client: client, runtime: runtime);
      await captured!({'uri': 'r://x'});

      verifyNever(() => runtime.handleNotification(any(),
          resourceReader: any(named: 'resourceReader')));

      // Now initialized
      when(() => runtime.isInitialized).thenReturn(true);
      when(() => runtime.handleNotification(any(),
              resourceReader: any(named: 'resourceReader')))
          .thenAnswer((_) async {});
      await captured!({'uri': 'r://x'});
      verify(() => runtime.handleNotification(any(),
          resourceReader: any(named: 'resourceReader'))).called(1);
    });

    test('TC-NOTIF-006: handler swallows runtime errors', () async {
      Function(Map<String, dynamic>)? captured;
      when(() => client.onNotification(any(), any())).thenAnswer((inv) {
        captured = inv.positionalArguments[1] as Function(Map<String, dynamic>);
      });
      when(() => runtime.isInitialized).thenReturn(true);
      when(() => runtime.handleNotification(any(),
              resourceReader: any(named: 'resourceReader')))
          .thenThrow(StateError('boom'));

      NotificationRouter().register(client: client, runtime: runtime);

      // Should not throw even though handleNotification throws.
      await captured!({'uri': 'r://x'});
    });
  });
}
