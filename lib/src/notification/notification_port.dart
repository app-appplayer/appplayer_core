/// Notification seam (FR-NOTIF).
///
/// Core contract; real implementation is the core plugin's native code.
/// Tests / unsupported platforms use [NoOpNotificationPort].
///
/// See `docs/03_DDD/platform-integration-foundation.md`.
library;

import 'dart:async';

import '../session/app_handle.dart';
import '../permission/platform_permission_port.dart';

/// A notification an app (bundle / server) asks the host to display.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.source,
  });

  final String id;
  final String title;
  final String body;

  /// The app that posted it — used to route a tap back to that app.
  final AppHandle source;
}

/// Named `AppNotificationPort` (not `NotificationPort`) to avoid colliding
/// with `mcp_bundle`'s workflow `NotificationPort`, a different concept.
abstract class AppNotificationPort {
  Future<PermissionStatus> permissionStatus();
  Future<PermissionStatus> requestPermission();
  Future<void> post(AppNotification notification);
  Future<void> cancel(String id);

  /// Emits the source app when the user taps its notification, so the host
  /// can open that app (FR-NOTIF-004).
  Stream<AppHandle> get taps;
}

/// Default for tests and platforms without notifications: posts are dropped,
/// permission reads as granted, no taps.
class NoOpNotificationPort implements AppNotificationPort {
  const NoOpNotificationPort();

  @override
  Future<PermissionStatus> permissionStatus() async =>
      PermissionStatus.granted;

  @override
  Future<PermissionStatus> requestPermission() async =>
      PermissionStatus.granted;

  @override
  Future<void> post(AppNotification notification) async {}

  @override
  Future<void> cancel(String id) async {}

  @override
  Stream<AppHandle> get taps => const Stream.empty();
}
