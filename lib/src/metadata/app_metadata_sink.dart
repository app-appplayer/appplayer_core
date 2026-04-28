import 'app_metadata.dart';

/// Host-injected sink for app metadata updates (NFR-EXT-007).
///
/// Called when the core acquires metadata during `openAppFromServer` /
/// `openAppFromBundle`. Sink failures are swallowed with a warning to avoid
/// blocking application load (FR-META-004).
abstract class AppMetadataSink {
  Future<void> onMetadata(AppMetadata metadata);
}
