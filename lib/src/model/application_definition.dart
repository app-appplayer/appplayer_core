/// Runtime-ready application definition common to Online and Local Bundle
/// sources (MOD-MODEL-005, FR-APP-002).
typedef PageLoaderFn = Future<Map<String, dynamic>> Function(String uri);

enum ApplicationSourceKind { online, localBundle }

class ApplicationDefinition {
  const ApplicationDefinition({
    required this.json,
    required this.pageLoader,
    required this.sourceKind,
    this.appId,
  });

  /// JSON payload accepted by `MCPUIRuntime.initialize`.
  final Map<String, dynamic> json;

  /// Page loader closure for lazy route resolution.
  final PageLoaderFn pageLoader;

  /// Provenance label.
  final ApplicationSourceKind sourceKind;

  /// `serverId` for Online, `bundle.manifest.id` for Local Bundle.
  final String? appId;
}
