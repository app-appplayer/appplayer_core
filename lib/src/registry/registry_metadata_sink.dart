import '../metadata/app_metadata.dart';
import '../metadata/app_metadata_sink.dart';
import 'apps_registry.dart';

/// Default [AppMetadataSink] that writes metadata back into the shell's
/// [AppsRegistry]. When [AppMetadataProvider.publish] fires, the
/// matching registry entry is updated via the shell-supplied [merge]
/// callback so the launcher tile re-renders with the fresh `name` /
/// `iconUrl` / `metadataJson` without bespoke wiring.
///
/// Wired automatically by `AppPlayerCoreService.initialize` when
/// `appsRegistry` is provided. Shells that need extra processing (e.g.
/// analytics) can chain additional sinks via [ChainedAppMetadataSink].
class RegistryMetadataSink<T> implements AppMetadataSink {
  RegistryMetadataSink({
    required AppsRegistry<T> registry,
    required T Function(T existing, AppMetadata metadata) merge,
  })  : _registry = registry,
        _merge = merge;

  final AppsRegistry<T> _registry;
  final T Function(T existing, AppMetadata metadata) _merge;

  @override
  Future<void> onMetadata(AppMetadata metadata) async {
    final existing = _registry.byId(metadata.appId);
    if (existing == null) return;
    final updated = _merge(existing, metadata);
    if (identical(existing, updated)) return;
    await _registry.update(updated);
  }
}

/// Forwards metadata to multiple sinks in declaration order. Failures in
/// one sink do not prevent the next from running.
class ChainedAppMetadataSink implements AppMetadataSink {
  ChainedAppMetadataSink(this._sinks);
  final List<AppMetadataSink> _sinks;

  @override
  Future<void> onMetadata(AppMetadata metadata) async {
    for (final s in _sinks) {
      try {
        await s.onMetadata(metadata);
      } catch (_) {
        // swallow — chaining must not abort on a single sink failure
      }
    }
  }
}
