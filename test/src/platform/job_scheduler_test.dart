import 'dart:async';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Background port that records background-job delegation.
class _RecordingBackground implements BackgroundExecutionPort {
  final List<String> backgroundJobs = [];

  @override
  Future<void> initialize(BackgroundPolicy policy) async {}

  @override
  Future<bool> beginBackground() async => true;

  @override
  Future<void> endBackground() async {}

  @override
  bool get isActive => false;

  @override
  Stream<BackgroundWake> get wakes => const Stream.empty();

  @override
  Future<void> runBackgroundJob(String jobId) async {
    backgroundJobs.add(jobId);
  }
}

void main() {
  group('JobScheduler', () {
    test('register starts a foreground timer that fires runNow', () async {
      final scheduler = JobScheduler(background: _RecordingBackground());
      var runs = 0;
      scheduler.register(ScheduledJob(
        id: 'tick',
        interval: const Duration(milliseconds: 10),
        run: () async => runs++,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 35));
      scheduler.dispose();
      expect(runs, greaterThanOrEqualTo(2));
    });

    test('runNow retries once on failure then gives up', () async {
      final scheduler = JobScheduler(background: _RecordingBackground());
      var attempts = 0;
      scheduler.register(ScheduledJob(
        id: 'flaky',
        interval: const Duration(hours: 1), // no timer interference
        run: () async {
          attempts++;
          throw StateError('boom');
        },
      ));

      await scheduler.runNow('flaky');
      expect(attempts, 2, reason: 'one initial + one retry');
      scheduler.dispose();
    });

    test('pauseForeground stops timers, resumeForeground restarts them', () async {
      final scheduler = JobScheduler(background: _RecordingBackground());
      var runs = 0;
      scheduler.register(ScheduledJob(
        id: 'tick',
        interval: const Duration(milliseconds: 10),
        run: () async => runs++,
      ));

      scheduler.pauseForeground();
      expect(scheduler.foregroundActive, isFalse);
      final pausedRuns = runs;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(runs, pausedRuns, reason: 'no timer fires while paused');

      scheduler.resumeForeground();
      expect(scheduler.foregroundActive, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(runs, greaterThan(pausedRuns));
      scheduler.dispose();
    });

    test('handleWake delegates a registered job to the background port', () async {
      final background = _RecordingBackground();
      final scheduler = JobScheduler(background: background);
      scheduler.register(ScheduledJob(
        id: 'sync',
        interval: const Duration(hours: 1),
        run: () async {},
      ));

      await scheduler.handleWake('sync');
      expect(background.backgroundJobs, ['sync']);

      await scheduler.handleWake('unregistered');
      expect(background.backgroundJobs, ['sync'],
          reason: 'unknown jobs are ignored');
      scheduler.dispose();
    });

    test('unregister removes the job and stops its timer', () async {
      final scheduler = JobScheduler(background: _RecordingBackground());
      var runs = 0;
      scheduler.register(ScheduledJob(
        id: 'tick',
        interval: const Duration(milliseconds: 10),
        run: () async => runs++,
      ));
      scheduler.unregister('tick');
      expect(scheduler.isRegistered('tick'), isFalse);
      final after = runs;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(runs, after);
      scheduler.dispose();
    });
  });

  group('NoOp platform ports', () {
    test('NoOpPlatformPermissionPort grants everything', () async {
      const port = NoOpPlatformPermissionPort();
      expect(await port.status(PlatformPermission.bluetooth),
          PermissionStatus.granted);
      expect(await port.request(PlatformPermission.location),
          PermissionStatus.granted);
    });

    test('NoOpNotificationPort drops posts and never taps', () async {
      const port = NoOpNotificationPort();
      expect(await port.requestPermission(), PermissionStatus.granted);
      await port.post(AppNotification(
        id: 'n1',
        title: 't',
        body: 'b',
        source: const AppHandle.server('s'),
      ));
      await port.cancel('n1');
      expect(await port.taps.isEmpty, isTrue);
    });

    test('NoOpBackgroundExecutionPort never grants background', () async {
      const port = NoOpBackgroundExecutionPort();
      expect(await port.beginBackground(), isFalse);
      expect(port.isActive, isFalse);
      expect(await port.wakes.isEmpty, isTrue);
    });
  });
}
