/// Background execution seam (FR-BGX).
///
/// The core defines this contract; the real implementation is the core's own
/// Flutter-plugin native code (method channel) — `appplayer_core` is a
/// multi-platform Flutter package, so it is promoted to a plugin and carries
/// the native adapters itself (single package). Tests and unsupported
/// platforms use [NoOpBackgroundExecutionPort].
library;

import 'dart:async';

import 'background_policy.dart';

abstract class BackgroundExecutionPort {
  /// Prepare the port for the given policy (no-op for `pauseResume`).
  Future<void> initialize(BackgroundPolicy policy);

  /// Request continued execution in the background. Returns whether the
  /// platform granted it (Android foreground service / iOS allowed mode).
  Future<bool> beginBackground();

  /// Release background execution.
  Future<void> endBackground();

  /// Whether background execution is currently active.
  bool get isActive;

  /// Platform wakes (BLE notify, push, fetch window) delivered while the app
  /// is backgrounded — the drive signal for continuity + scheduled jobs.
  Stream<BackgroundWake> get wakes;

  /// Run a scheduled job identified by [jobId] in a platform background task
  /// window (WorkManager / BGTaskScheduler). No-op where unsupported.
  Future<void> runBackgroundJob(String jobId);
}

/// Default for tests and platforms without background support (desktop/web):
/// nothing runs in the background, foreground behaviour is unaffected.
class NoOpBackgroundExecutionPort implements BackgroundExecutionPort {
  const NoOpBackgroundExecutionPort();

  @override
  Future<void> initialize(BackgroundPolicy policy) async {}

  @override
  Future<bool> beginBackground() async => false;

  @override
  Future<void> endBackground() async {}

  @override
  bool get isActive => false;

  @override
  Stream<BackgroundWake> get wakes => const Stream.empty();

  @override
  Future<void> runBackgroundJob(String jobId) async {}
}
