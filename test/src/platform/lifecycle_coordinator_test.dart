import 'dart:async';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records continuity calls so lifecycle reactions can be asserted without a
/// real ConnectionManager.
class _FakeContinuity implements ContinuityController {
  int pauses = 0;
  int resumes = 0;
  int sweeps = 0;

  @override
  Future<void> pauseAll() async => pauses++;

  @override
  Future<void> resumeAll() async => resumes++;

  @override
  Future<void> sweepStale() async => sweeps++;
}

/// Background port whose `beginBackground()` grant is configurable and whose
/// wake stream can be driven by the test.
class _FakeBackground implements BackgroundExecutionPort {
  _FakeBackground({this.grant = true});

  final bool grant;
  bool _active = false;
  int begins = 0;
  int ends = 0;
  final List<String> backgroundJobs = [];
  final StreamController<BackgroundWake> _wakes =
      StreamController<BackgroundWake>.broadcast();

  void emitWake(BackgroundWake wake) => _wakes.add(wake);
  Future<void> close() => _wakes.close();

  @override
  Future<void> initialize(BackgroundPolicy policy) async {}

  @override
  Future<bool> beginBackground() async {
    begins++;
    _active = grant;
    return grant;
  }

  @override
  Future<void> endBackground() async {
    ends++;
    _active = false;
  }

  @override
  bool get isActive => _active;

  @override
  Stream<BackgroundWake> get wakes => _wakes.stream;

  @override
  Future<void> runBackgroundJob(String jobId) async {
    backgroundJobs.add(jobId);
  }
}

class _FakeReclaimer implements MemoryReclaimer {
  int reclaims = 0;

  @override
  Future<void> reclaim() async => reclaims++;
}

void main() {
  group('LifecycleCoordinator', () {
    test('pauseResume: background pauses continuity, foreground resumes', () async {
      final continuity = _FakeContinuity();
      final background = _FakeBackground();
      final coordinator = LifecycleCoordinator(
        continuity: continuity,
        background: background,
        policy: BackgroundPolicy.pauseResume,
      );

      await coordinator.onPhase(AppLifecyclePhase.background);
      expect(continuity.pauses, 1);
      expect(background.begins, 0, reason: 'pauseResume never asks to keep alive');

      await coordinator.onPhase(AppLifecyclePhase.foreground);
      expect(continuity.resumes, 1);
      expect(coordinator.phase, AppLifecyclePhase.foreground);
    });

    test('keepAlive: granted background stays alive without pausing', () async {
      final continuity = _FakeContinuity();
      final background = _FakeBackground(grant: true);
      final coordinator = LifecycleCoordinator(
        continuity: continuity,
        background: background,
        policy: BackgroundPolicy.keepAlive,
      );

      await coordinator.onPhase(AppLifecyclePhase.background);
      expect(background.begins, 1);
      expect(continuity.pauses, 0, reason: 'grant means no fallback pause');
    });

    test('keepAlive: denied background falls back to pausing', () async {
      final continuity = _FakeContinuity();
      final background = _FakeBackground(grant: false);
      final coordinator = LifecycleCoordinator(
        continuity: continuity,
        background: background,
        policy: BackgroundPolicy.keepAlive,
      );

      await coordinator.onPhase(AppLifecyclePhase.background);
      expect(background.begins, 1);
      expect(continuity.pauses, 1, reason: 'denied grant triggers fallback');
    });

    test('foreground ends any active background execution', () async {
      final background = _FakeBackground(grant: true);
      final coordinator = LifecycleCoordinator(
        continuity: _FakeContinuity(),
        background: background,
        policy: BackgroundPolicy.keepAlive,
      );

      await coordinator.onPhase(AppLifecyclePhase.background);
      expect(background.isActive, isTrue);

      await coordinator.onPhase(AppLifecyclePhase.foreground);
      expect(background.ends, 1);
      expect(background.isActive, isFalse);
    });

    test('memoryPressure reclaims without changing the persistent phase', () async {
      final reclaimer = _FakeReclaimer();
      final coordinator = LifecycleCoordinator(
        continuity: _FakeContinuity(),
        background: _FakeBackground(),
        policy: BackgroundPolicy.pauseResume,
        memory: reclaimer,
      );

      await coordinator.onPhase(AppLifecyclePhase.foreground);
      await coordinator.onPhase(AppLifecyclePhase.memoryPressure);

      expect(reclaimer.reclaims, 1);
      expect(coordinator.phase, AppLifecyclePhase.foreground,
          reason: 'memoryPressure is transient, not a phase');
    });

    test('NoOp background: pauseResume host runs without error', () async {
      final coordinator = LifecycleCoordinator(
        continuity: _FakeContinuity(),
        background: const NoOpBackgroundExecutionPort(),
        policy: BackgroundPolicy.pauseResume,
      );

      await coordinator.onPhase(AppLifecyclePhase.background);
      await coordinator.onPhase(AppLifecyclePhase.foreground);
      expect(coordinator.phase, AppLifecyclePhase.foreground);
    });

    test('desktop (platformSuspends=false): background never pauses connections',
        () async {
      final continuity = _FakeContinuity();
      final background = _FakeBackground();
      final coordinator = LifecycleCoordinator(
        continuity: continuity,
        background: background,
        policy: BackgroundPolicy.pauseResume,
        platformSuspends: false,
      );

      await coordinator.onPhase(AppLifecyclePhase.background);
      await coordinator.onPhase(AppLifecyclePhase.foreground);

      expect(continuity.pauses, 0, reason: 'desktop must not disconnect');
      expect(continuity.resumes, 0);
      expect(background.begins, 0);
      await background.close();
    });
  });

  group('LifecycleCoordinator — wake routing', () {
    test('bleNotify / push wakes trigger a stale sweep', () async {
      final continuity = _FakeContinuity();
      final background = _FakeBackground();
      final coordinator = LifecycleCoordinator(
        continuity: continuity,
        background: background,
        policy: BackgroundPolicy.keepAlive,
      );

      background.emitWake(const BackgroundWake(kind: BackgroundWakeKind.bleNotify));
      background.emitWake(const BackgroundWake(kind: BackgroundWakeKind.push));
      await Future<void>.delayed(Duration.zero);

      expect(continuity.sweeps, 2);
      await coordinator.dispose();
      await background.close();
    });

    test('fetchWindow wake delegates the job to the scheduler', () async {
      final background = _FakeBackground();
      final scheduler = JobScheduler(background: background);
      scheduler.register(ScheduledJob(
        id: 'sync',
        interval: const Duration(hours: 1),
        run: () async {},
      ));
      final coordinator = LifecycleCoordinator(
        continuity: _FakeContinuity(),
        background: background,
        policy: BackgroundPolicy.keepAlive,
        scheduler: scheduler,
      );

      background.emitWake(const BackgroundWake(
          kind: BackgroundWakeKind.fetchWindow, jobId: 'sync'));
      await Future<void>.delayed(Duration.zero);

      expect(background.backgroundJobs, ['sync']);
      await coordinator.dispose();
      scheduler.dispose();
      await background.close();
    });

    test('dispose stops routing further wakes', () async {
      final continuity = _FakeContinuity();
      final background = _FakeBackground();
      final coordinator = LifecycleCoordinator(
        continuity: continuity,
        background: background,
        policy: BackgroundPolicy.keepAlive,
      );

      await coordinator.dispose();
      background.emitWake(const BackgroundWake(kind: BackgroundWakeKind.push));
      await Future<void>.delayed(Duration.zero);

      expect(continuity.sweeps, 0, reason: 'no routing after dispose');
      await background.close();
    });
  });
}
