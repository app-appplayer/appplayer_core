/// Host-injected credential store (MOD-STOR-002, NFR-EXT-008).
///
/// Maps arbitrary keys (typically `ServerConfig.credentialKey`) to secret
/// values held in platform secure storage. The core never persists
/// credentials itself; it only reads when assembling transport configs.
abstract class CredentialVault {
  /// Returns the secret stored under [key], or `null` when absent.
  Future<String?> read(String key);

  /// Writes [value] under [key]. Overwrites any prior value.
  Future<void> write(String key, String value);

  /// Removes the entry under [key] if present.
  Future<void> delete(String key);
}

/// No-op implementation used when the host does not configure a vault.
class NoopCredentialVault implements CredentialVault {
  const NoopCredentialVault();

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
