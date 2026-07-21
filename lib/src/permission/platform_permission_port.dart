/// Platform (OS) permission seam (FR-PERM).
///
/// Core contract; real implementation is the core plugin's native code.
/// Tests / desktop use [NoOpPlatformPermissionPort] (everything granted).
library;

import 'dart:async';

/// OS-level permissions the platform features require.
enum PlatformPermission {
  backgroundExecution,
  bluetooth,
  localNetwork,
  location,
  notifications,
  usb,
  camera,
  microphone,
}

enum PermissionStatus { granted, denied, restricted, notDetermined }

abstract class PlatformPermissionPort {
  /// Current status without prompting.
  Future<PermissionStatus> status(PlatformPermission permission);

  /// Request the permission (lazily, at the point the feature needs it).
  Future<PermissionStatus> request(PlatformPermission permission);

  /// Emits when any permission status may have changed.
  Stream<void> get changes;
}

/// Default for tests and platforms without a permission model (desktop):
/// every permission reads as granted; requests are no-ops.
class NoOpPlatformPermissionPort implements PlatformPermissionPort {
  const NoOpPlatformPermissionPort();

  @override
  Future<PermissionStatus> status(PlatformPermission permission) async =>
      PermissionStatus.granted;

  @override
  Future<PermissionStatus> request(PlatformPermission permission) async =>
      PermissionStatus.granted;

  @override
  Stream<void> get changes => const Stream.empty();
}
