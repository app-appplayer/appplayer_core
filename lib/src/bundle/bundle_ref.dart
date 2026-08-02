/// Reference to a bundle source (MOD-MODEL-005).
sealed class BundleRef {
  const BundleRef();
}

/// Pre-decoded JSON payload.
class BundleInlineRef extends BundleRef {
  const BundleInlineRef(this.json);
  final Map<String, dynamic> json;
}

/// Local filesystem path. Host is expected to pre-resolve file contents
/// into a [BundleInlineRef] when running in environments where the core
/// must not perform `dart:io` access (NFR-PORT-004).
class BundleFileRef extends BundleRef {
  const BundleFileRef(this.path);
  final String path;
}

/// Remote HTTP(S) URL. Requires a `BundleFetcher` injection.
class BundleRemoteRef extends BundleRef {
  const BundleRemoteRef(this.url, {this.headers});
  final Uri url;
  final Map<String, String>? headers;
}

/// Bundle already installed under Core's configured bundle install
/// destination (FR-BUNDLE-009).
///
/// Core resolves this through `mcp_bundle`, which preserves the bundle's
/// backing files — a `.mbd/` directory on hosts that have a filesystem,
/// a host-provided store on hosts that do not — so
/// [BundleApplicationAdapter] can read `ui/app.json` and page resources.
/// `BundleInlineRef` cannot substitute here: `McpBundle.toJson`
/// deliberately omits that anchor, so a round-trip drops it and trips
/// `BundleAdaptException(unsupportedEntryPoint)`.
class BundleInstalledRef extends BundleRef {
  const BundleInstalledRef(this.bundleId);
  final String bundleId;
}
