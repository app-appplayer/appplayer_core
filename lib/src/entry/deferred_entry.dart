/// Surviving an install (platform spec 19 §3.5).
///
/// Someone taps an entry link, has no app, goes to the store, installs, and
/// launches. Landing on the home screen there is the failure they cannot
/// recover from: the medium is usually no longer in front of them.
///
/// Platforms differ in whether the code can be carried across that gap, so the
/// obligation is graded — carry it where the platform allows, and where it
/// does not, offer an explicit way back rather than pretending nothing was
/// asked for.
library;

import '../logging/logger.dart';

/// Reads a code the platform carried across an install, if it can.
///
/// A host that has no such mechanism supplies **no source at all** — that
/// absence is meaningful, and is what turns the obligation into an offer of
/// manual recovery instead of silence.
abstract class DeferredEntrySource {
  /// The entry code this install came from, or `null` when the install was
  /// not started from an entry.
  Future<String?> pendingCode();
}

/// Remembers whether this launch is the first after an install.
abstract class FirstLaunchStore {
  Future<bool> isFirstLaunch();
  Future<void> markLaunched();
}

/// What the host should do at launch.
enum DeferredEntryOutcome {
  /// Nothing to do: a later launch, or a platform that told us this install
  /// began somewhere other than an entry.
  none,

  /// A code survived the install. Resolve it as though the link had just been
  /// opened — never from a cached answer, since custody may have changed while
  /// the store was busy (§6.4).
  recovered,

  /// This platform cannot carry a code across an install, and this is the
  /// first launch. Offer a way back — a rescan, or reopening the link —
  /// rather than landing silently on home.
  offerRecovery,
}

/// The result, with the code when there is one.
class DeferredEntry {
  const DeferredEntry(this.outcome, [this.code]);

  final DeferredEntryOutcome outcome;
  final String? code;

  bool get hasCode => code != null && code!.isNotEmpty;
}

/// Decides what a launch means. Pure: the platform pieces are the source and
/// the store, and both are injected.
class DeferredEntryResolver {
  DeferredEntryResolver({
    required FirstLaunchStore store,
    DeferredEntrySource? source,
    Logger? logger,
  })  : _store = store,
        _source = source,
        _logger = logger ?? NoopLogger();

  final FirstLaunchStore _store;
  final DeferredEntrySource? _source;
  final Logger _logger;

  /// Call once at launch, before anything decides what to show.
  ///
  /// The launch is marked as seen either way: a recovery offered twice is a
  /// nag, and a code recovered twice would open the same entry again on a
  /// launch the viewer did not connect to it.
  Future<DeferredEntry> onLaunch() async {
    if (!await _store.isFirstLaunch()) {
      return const DeferredEntry(DeferredEntryOutcome.none);
    }
    await _store.markLaunched();

    final source = _source;
    if (source == null) {
      // No mechanism on this platform. Silence here is the failure the
      // standard names; an offer costs one dismissible affordance.
      return const DeferredEntry(DeferredEntryOutcome.offerRecovery);
    }

    try {
      final code = await source.pendingCode();
      if (code == null || code.isEmpty) {
        // The platform answered and said this install did not come from an
        // entry. Offering recovery here would be a prompt about something
        // that never happened.
        return const DeferredEntry(DeferredEntryOutcome.none);
      }
      return DeferredEntry(DeferredEntryOutcome.recovered, code);
    } catch (e) {
      // A mechanism that failed is a mechanism we do not have.
      _logger.warn('entry.deferred.source_failed', {'error': e.toString()});
      return const DeferredEntry(DeferredEntryOutcome.offerRecovery);
    }
  }
}
