/// Periodic / scheduled background jobs (FR-SCHED).
///
/// Foreground: an internal periodic timer per job. Background: delegated to
/// [BackgroundExecutionPort.runBackgroundJob] (platform WorkManager /
/// BGTaskScheduler).
library;

import 'dart:async';

import '../background/background_execution_port.dart';
import '../logging/logger.dart';

class ScheduledJob {
  const ScheduledJob({
    required this.id,
    required this.interval,
    required this.run,
  });

  final String id;
  final Duration interval;
  final Future<void> Function() run;
}

class JobScheduler {
  JobScheduler({
    required BackgroundExecutionPort background,
    Logger? logger,
  })  : _background = background,
        _logger = logger ?? NoopLogger();

  final BackgroundExecutionPort _background;
  final Logger _logger;

  final Map<String, ScheduledJob> _jobs = {};
  final Map<String, Timer> _timers = {};
  bool _foregroundActive = true;

  bool get foregroundActive => _foregroundActive;
  bool isRegistered(String id) => _jobs.containsKey(id);

  /// Register a job. When the foreground is active it starts a periodic timer;
  /// re-registering the same id replaces it.
  void register(ScheduledJob job) {
    unregister(job.id);
    _jobs[job.id] = job;
    if (_foregroundActive) _startTimer(job);
  }

  void unregister(String id) {
    _timers.remove(id)?.cancel();
    _jobs.remove(id);
  }

  /// Run a job once now, guarding + retrying once on failure (FR-SCHED-003
  /// idempotent/retry). Safe to call from a foreground timer or a background
  /// wake.
  Future<void> runNow(String id) async {
    final job = _jobs[id];
    if (job == null) return;
    try {
      await job.run();
    } catch (e) {
      _logger.warn('schedule.job.failed', {'id': id, 'cause': '$e'});
      try {
        await job.run(); // single retry
      } catch (e2, st2) {
        _logger.logError('schedule.job.retry_failed', e2, st2);
      }
    }
  }

  /// Background entry (FR-SCHED-002): delegate to the platform background
  /// task. The port runs the job in its task window; where unsupported the
  /// job is simply skipped until the next foreground tick.
  Future<void> handleWake(String jobId) async {
    if (!isRegistered(jobId)) return;
    await _background.runBackgroundJob(jobId);
  }

  /// Entering background — stop foreground timers (they would freeze anyway).
  void pauseForeground() {
    _foregroundActive = false;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  /// Returning to foreground — restart timers for every registered job.
  void resumeForeground() {
    _foregroundActive = true;
    for (final job in _jobs.values) {
      _startTimer(job);
    }
  }

  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _jobs.clear();
  }

  void _startTimer(ScheduledJob job) {
    _timers[job.id]?.cancel();
    _timers[job.id] = Timer.periodic(job.interval, (_) => runNow(job.id));
  }
}
