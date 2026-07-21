/// Background continuity policy + wake events (FR-BGX-005, FR-BGX-004).
///
/// Part of the Platform Integration Foundation.
library;

/// How a connection behaves when the app enters the background.
enum BackgroundPolicy {
  /// Snapshot resume cursors and pause connections; reconnect + catch-up on
  /// return. Battery/OS-policy friendly — the default.
  pauseResume,

  /// Keep connections alive in the background (Android foreground service /
  /// iOS allowed modes). Opt-in for monitoring / control apps.
  keepAlive,
}

/// Reason the platform woke the app in the background.
enum BackgroundWakeKind {
  /// A BLE peripheral pushed a notification.
  bleNotify,

  /// A remote push (APNs / FCM) arrived.
  push,

  /// A periodic background-fetch / task window opened.
  fetchWindow,
}

/// A background wake signal delivered by [BackgroundExecutionPort.wakes].
class BackgroundWake {
  const BackgroundWake({required this.kind, this.serverId, this.jobId});

  final BackgroundWakeKind kind;

  /// The server the wake pertains to, when known (e.g. a BLE notify).
  final String? serverId;

  /// The scheduled job to run, when the wake opened a task window.
  final String? jobId;

  @override
  String toString() =>
      'BackgroundWake(${kind.name}, server: $serverId, job: $jobId)';
}
