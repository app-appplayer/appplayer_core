import 'package:flutter/foundation.dart';

/// MOD-CORE-REG — single source of truth for the user's registered app
/// list. Reactive surface so shells (Standard / Pro / X / Custom) can
/// listen via `ValueListenableBuilder` or `Provider.watch` and rebuild
/// automatically when the list changes (add / remove / update / metadata
/// arrival).
///
/// Generic over `T` so core does not depend on the shell's `AppConfig`
/// shape — shells inject decode / encode / id-of callbacks via
/// [PrefsAppsRegistry] (default impl) or supply their own
/// implementation.
abstract class AppsRegistry<T> implements ValueListenable<List<T>> {
  /// Returns the registered entry whose id matches [appId], or `null`.
  T? byId(String appId);

  /// Adds [app]. Replaces any existing entry with the same id.
  Future<void> add(T app);

  /// Replaces the entry whose id matches [app]'s id. No-op if missing.
  Future<void> update(T app);

  /// Removes the entry whose id matches [appId]. No-op if missing.
  Future<void> remove(String appId);
}
