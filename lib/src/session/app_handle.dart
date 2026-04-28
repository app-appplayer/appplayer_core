/// Public handle identifying an opened app session.
///
/// Separates the `serverId` and `bundle.manifest.id` namespaces so runtime
/// registries can key on [AppHandle] without collision (MOD-SESSION-003,
/// FR-SESSION-006).
library;

enum AppSource { server, bundle }

class AppHandle {
  const AppHandle.server(String serverId)
      : source = AppSource.server,
        key = serverId;

  const AppHandle.bundle(String bundleId)
      : source = AppSource.bundle,
        key = bundleId;

  final AppSource source;
  final String key;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppHandle && other.source == source && other.key == key;

  @override
  int get hashCode => Object.hash(source, key);

  @override
  String toString() => '${source.name}:$key';
}
