/// Lifecycle intake + continuity policy (FR-LIFE, FR-MEM, FR-BGX wakes).
///
/// The shell forwards raw `AppLifecycleState` here; this coordinator applies
/// the [BackgroundPolicy] and routes background wake events. Pure Dart —
/// driven by [onPhase] / the injected wake stream — so it is unit-testable
/// without a widget binding.
library;

import 'dart:async';

import '../background/background_execution_port.dart';
import '../background/background_policy.dart';
import '../connection/continuity_controller.dart';
import '../logging/logger.dart';
import '../schedule/job_scheduler.dart';

/// App lifecycle phases the core reacts to. Mirrors Flutter's
/// `AppLifecycleState` plus an explicit `memoryPressure` signal.
enum AppLifecyclePhase { foreground, background, inactive, detached, memoryPressure }

/// Reclaims re-creatable memory (caches, inactive runtimes) under memory
/// pressure (FR-MEM). Active sessions and persisted data are preserved.
abstract class MemoryReclaimer {
  Future<void> reclaim();
}

class LifecycleCoordinator {
  LifecycleCoordinator({
    required ContinuityController continuity,
    required BackgroundExecutionPort background,
    required BackgroundPolicy policy,
    JobScheduler? scheduler,
    MemoryReclaimer? memory,
    Logger? logger,
    bool platformSuspends = true,
  })  : _continuity = continuity,
        _background = background,
        _policy = policy,
        _scheduler = scheduler,
        _memory = memory,
        _platformSuspends = platformSuspends,
        _logger = logger ?? NoopLogger() {
    // Route platform wakes (BLE notify / push / fetch window) to a stale-sweep
    // or a scheduled job (FR-BGX-004, FR-SCHED-002). On desktop the NoOp port
    // emits nothing, so this subscription is inert.
    _wakeSub = _background.wakes.listen(_onWake);
  }

  final ContinuityController _continuity;
  final BackgroundExecutionPort _background;
  final BackgroundPolicy _policy;
  final JobScheduler? _scheduler;
  final MemoryReclaimer? _memory;
  final Logger _logger;

  /// Whether the platform suspends the process in the background (mobile). On
  /// desktop this is false: hiding / minimizing the window must NOT pause or
  /// disconnect connections, so [onPhase] skips the continuity actions.
  final bool _platformSuspends;

  StreamSubscription<BackgroundWake>? _wakeSub;

  AppLifecyclePhase? _phase;
  AppLifecyclePhase? get phase => _phase;

  Future<void> onPhase(AppLifecyclePhase phase) async {
    _logger.debug('lifecycle.phase', {'phase': phase.name});
    switch (phase) {
      case AppLifecyclePhase.foreground:
        _phase = phase;
        if (_platformSuspends) await _onForeground();
      case AppLifecyclePhase.background:
        _phase = phase;
        if (_platformSuspends) await _onBackground();
      case AppLifecyclePhase.memoryPressure:
        // Not a persistent phase — reclaim without changing `_phase`. Applies
        // on every platform (desktop apps can be memory-pressured too).
        await _memory?.reclaim();
      case AppLifecyclePhase.inactive:
      case AppLifecyclePhase.detached:
        // Transient / terminal — connection teardown is the observer's job.
        _phase = phase;
    }
  }

  Future<void> _onForeground() async {
    if (_background.isActive) await _background.endBackground();
    _scheduler?.resumeForeground();
    await _continuity.resumeAll();
  }

  Future<void> _onBackground() async {
    switch (_policy) {
      case BackgroundPolicy.keepAlive:
        // Try to keep running; if the platform denies, fall back to pausing.
        final granted = await _background.beginBackground();
        if (!granted) {
          _scheduler?.pauseForeground();
          await _continuity.pauseAll();
        }
      case BackgroundPolicy.pauseResume:
        _scheduler?.pauseForeground();
        await _continuity.pauseAll();
    }
  }

  Future<void> _onWake(BackgroundWake wake) async {
    _logger.debug('lifecycle.wake', {'kind': wake.kind.name});
    switch (wake.kind) {
      case BackgroundWakeKind.bleNotify:
      case BackgroundWakeKind.push:
        // A peripheral/server signalled data — reconnect anything stale so the
        // catch-up can flow.
        await _continuity.sweepStale();
      case BackgroundWakeKind.fetchWindow:
        final jobId = wake.jobId;
        if (jobId != null) await _scheduler?.handleWake(jobId);
    }
  }

  Future<void> dispose() async {
    await _wakeSub?.cancel();
    _wakeSub = null;
  }
}
