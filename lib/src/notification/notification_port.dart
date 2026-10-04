/// Notification seam (FR-NOTIF).
///
/// Core contract; real implementation is the core plugin's native code.
/// Tests / unsupported platforms use [NoOpNotificationPort].
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
    this.at,
    this.expiresAt,
  });

  final String id;

  /// When to show it — null for now. A later time is handed to the operating
  /// system, so it is shown even if this process is suspended by then (a
  /// reminder that a bought time is running out). Posting the same [id]
  /// again replaces it; [AppNotificationPort.cancel] withdraws it whether it
  /// is still waiting or already shown.
  final DateTime? at;

  /// After this time it is not shown at all — what it says has stopped being
  /// true ("30 s left" once the time is over). A system that delivers a
  /// scheduled notification late drops it instead of showing it late.
  final DateTime? expiresAt;
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

/// A port on a platform where on-time delivery of notifications posted for
/// later is a separate grant (Android 12+ "Alarms & reminders"). Elsewhere a
/// later notification is already shown on time and a port has nothing to
/// offer here, so this is a capability a port has or lacks, not a duty of
/// every port. A caller matches for it:
/// `if (port case final ExactNotificationTiming t) await t.requestExactTiming();`
abstract class ExactNotificationTiming {
  /// Asks for notifications posted for later to be shown at their exact time
  /// rather than when the system finds convenient. True when they will be;
  /// false when the person still has to allow it (the system screen has been
  /// opened for them) or it cannot be had.
  Future<bool> requestExactTiming();
}

/// Default for tests and platforms without notifications: posts are dropped,
/// permission reads as granted, no taps.
class NoOpNotificationPort implements AppNotificationPort {
  const NoOpNotificationPort();

  @override
  Future<PermissionStatus> permissionStatus() async => PermissionStatus.granted;

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
