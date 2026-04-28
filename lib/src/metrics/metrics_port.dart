/// Observability metrics port (MOD-OBS-002, NFR-EXT-009).
///
/// Hosts inject a real implementation (OpenTelemetry / Prometheus / Datadog
/// exporter). Core and tests default to [NoopMetricsPort].
abstract class MetricsPort {
  void recordLatency(
    String operation,
    Duration duration, {
    Map<String, String>? tags,
  });

  void recordCount(
    String metric, {
    int value = 1,
    Map<String, String>? tags,
  });

  void recordError(
    String operation,
    String errorType, {
    Map<String, String>? tags,
  });
}

class NoopMetricsPort implements MetricsPort {
  const NoopMetricsPort();

  @override
  void recordLatency(String operation, Duration duration, {Map<String, String>? tags}) {}

  @override
  void recordCount(String metric, {int value = 1, Map<String, String>? tags}) {}

  @override
  void recordError(String operation, String errorType, {Map<String, String>? tags}) {}
}
