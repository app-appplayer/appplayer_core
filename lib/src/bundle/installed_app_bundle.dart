/// Value object describing a bundle resident under Core's install root
/// (FR-INSTALL-006).
///
/// Core-owned type: hosts consume this from `installBundleFromX` /
/// `listInstalledBundles` without importing `mcp_bundle`. Mapped from
/// `mcp_bundle.InstalledBundle` inside `BundleInstallerAdapter`.
class InstalledAppBundle {
  const InstalledAppBundle({
    required this.id,
    required this.version,
    required this.installedAt,
    required this.installPath,
    this.signer,
  });

  /// Manifest id (stable handle for uninstall / `BundleInstalledRef`).
  final String id;

  /// Manifest version at install time.
  final String version;

  /// UTC moment the install sidecar was written.
  final DateTime installedAt;

  /// Absolute `.mbd/` directory path under Core's install root.
  final String installPath;

  /// `keyId` of the signer whose signature was verified, or `null` when
  /// the bundle was unsigned and policy permitted unsigned installs.
  final String? signer;
}
