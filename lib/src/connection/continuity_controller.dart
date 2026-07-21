/// Continuity control seam (FR-CONT / FR-LIFE).
///
/// The lifecycle coordinator drives connection continuity through this
/// interface; `ConnectionContinuity` (wired onto `ConnectionManager`)
/// implements it. Kept as a seam so the coordinator is unit-testable with a
/// fake.
library;

abstract class ContinuityController {
  /// Snapshot resume cursors and pause connections (background entry).
  Future<void> pauseAll();

  /// Reconnect + catch-up every paused/stale connection (foreground return).
  Future<void> resumeAll();

  /// Reconnect only connections found stale (wake-driven check).
  Future<void> sweepStale();
}
