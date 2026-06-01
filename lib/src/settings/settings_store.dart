/// `SettingsStore` host port — persists the per-bundle user setting
/// values declared by the bundle's `settings.sections[].fields[]` schema.
///
/// The core is unaware of the storage implementation. Each host
/// (Standard / Pro / X / Custom) supplies its own implementation
/// backed by SharedPreferences, SecureStorage, files, or any other
/// strategy — matching the pattern of the other AppPlayer host ports
/// (`ServerStorage`, `CredentialVault`).
///
/// JS tools call this port through the (future) `host.settings.*`
/// atom. The Standard settings dialog renders the bundle's
/// `settings.sections` schema as a form and persists user input back
/// through this port.
library;

abstract class SettingsStore {
  /// Read every setting for a bundle in a single batch. Unwritten
  /// fields do not get filled with schema defaults — the caller
  /// composes defaults (the core has no knowledge of the schema).
  Future<Map<String, dynamic>> readAll(String bundleId);

  /// Write every setting for a bundle at once (overwrite). Existing
  /// keys not present in `values` are kept or removed per host policy.
  Future<void> writeAll(String bundleId, Map<String, dynamic> values);

  /// Read a single field. Returns null when the field has not been
  /// stored yet.
  Future<Object?> read(String bundleId, String fieldName);

  /// Write a single field.
  Future<void> write(String bundleId, String fieldName, Object? value);

  /// Remove every setting for a bundle. Driven by the bundle uninstall
  /// lifecycle.
  Future<void> clear(String bundleId);
}

/// Core default — used when the host does not inject a `SettingsStore`
/// implementation. Lives in memory and clears on process restart, so
/// production hosts must always supply their own implementation.
class InMemorySettingsStore implements SettingsStore {
  final Map<String, Map<String, Object?>> _store =
      <String, Map<String, Object?>>{};

  @override
  Future<Map<String, dynamic>> readAll(String bundleId) async =>
      Map<String, dynamic>.from(_store[bundleId] ?? const <String, Object?>{});

  @override
  Future<void> writeAll(
    String bundleId,
    Map<String, dynamic> values,
  ) async {
    _store[bundleId] = Map<String, Object?>.from(values);
  }

  @override
  Future<Object?> read(String bundleId, String fieldName) async =>
      _store[bundleId]?[fieldName];

  @override
  Future<void> write(
    String bundleId,
    String fieldName,
    Object? value,
  ) async {
    final m = _store.putIfAbsent(bundleId, () => <String, Object?>{});
    m[fieldName] = value;
  }

  @override
  Future<void> clear(String bundleId) async {
    _store.remove(bundleId);
  }
}
