import 'package:appplayer_core/src/notification/notification_port.dart';
import 'package:appplayer_core/src/permission/platform_permission_port.dart';
import 'package:appplayer_core/src/platform_impl/method_channel_background.dart';
import 'package:appplayer_core/src/platform_impl/method_channel_notifications.dart';
import 'package:appplayer_core/src/platform_impl/method_channel_permissions.dart';
import 'package:appplayer_core/src/background/background_policy.dart';
import 'package:appplayer_core/src/session/app_handle.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// With no native plugin registered (the flutter-test host), every method call
/// throws `MissingPluginException`; the ports must catch it and degrade to the
/// documented NoOp behaviour rather than surfacing the error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelBackgroundExecutionPort — no native → NoOp', () {
    final port = MethodChannelBackgroundExecutionPort();

    test('initialize / begin / end / runJob never throw and stay inactive',
        () async {
      await port.initialize(BackgroundPolicy.keepAlive);
      expect(await port.beginBackground(), isFalse);
      expect(port.isActive, isFalse);
      await port.endBackground();
      await port.runBackgroundJob('job-1');
      expect(port.isActive, isFalse);
    });
  });

  group('MethodChannelPlatformPermissionPort — no native → granted', () {
    final port = MethodChannelPlatformPermissionPort();

    test('status / request degrade to granted', () async {
      expect(await port.status(PlatformPermission.bluetooth),
          PermissionStatus.granted);
      expect(await port.request(PlatformPermission.notifications),
          PermissionStatus.granted);
    });
  });

  group('MethodChannelAppNotificationPort — no native → drop/granted', () {
    final port = MethodChannelAppNotificationPort();

    test('permission reads granted, post/cancel are silently dropped',
        () async {
      expect(await port.requestPermission(), PermissionStatus.granted);
      await port.post(AppNotification(
        id: 'n1',
        title: 't',
        body: 'b',
        source: const AppHandle.server('s'),
      ));
      await port.cancel('n1');
    });
  });

  group('MethodChannelBackgroundExecutionPort — native responses', () {
    test('beginBackground reflects a granted native result', () async {
      const channel = MethodChannel('makemind.appplayer_core/methods');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'background.begin') return true;
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      final port = MethodChannelBackgroundExecutionPort();
      expect(await port.beginBackground(), isTrue);
      expect(port.isActive, isTrue);
      await port.endBackground();
      expect(port.isActive, isFalse);
    });
  });
}
