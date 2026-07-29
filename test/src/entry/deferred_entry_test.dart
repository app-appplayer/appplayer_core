/// Surviving an install (platform spec 19 §3.5).
library;

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store implements FirstLaunchStore {
  _Store(this._first);
  bool _first;
  int marks = 0;

  @override
  Future<bool> isFirstLaunch() async => _first;

  @override
  Future<void> markLaunched() async {
    marks++;
    _first = false;
  }
}

class _Source implements DeferredEntrySource {
  _Source(this._code, {this.throws = false});
  final String? _code;
  final bool throws;

  @override
  Future<String?> pendingCode() async {
    if (throws) throw StateError('referrer unavailable');
    return _code;
  }
}

void main() {
  test('a later launch has nothing deferred', () async {
    final store = _Store(false);
    final result = await DeferredEntryResolver(
      store: store,
      source: _Source('ABC'),
    ).onLaunch();

    expect(result.outcome, DeferredEntryOutcome.none);
    expect(store.marks, 0, reason: 'nothing to mark on a later launch');
  });

  test('a code carried across the install is recovered', () async {
    final result = await DeferredEntryResolver(
      store: _Store(true),
      source: _Source('fleet/ABC123'),
    ).onLaunch();

    expect(result.outcome, DeferredEntryOutcome.recovered);
    expect(result.code, 'fleet/ABC123');
    expect(result.hasCode, isTrue);
  });

  test('a platform that says this install began elsewhere prompts nothing',
      () async {
    // Offering recovery here would be a prompt about something that never
    // happened — most installs have nothing to do with an entry.
    final result = await DeferredEntryResolver(
      store: _Store(true),
      source: _Source(null),
    ).onLaunch();

    expect(result.outcome, DeferredEntryOutcome.none);
  });

  test('an empty code counts as nothing pending', () async {
    final result = await DeferredEntryResolver(
      store: _Store(true),
      source: _Source(''),
    ).onLaunch();
    expect(result.outcome, DeferredEntryOutcome.none);
  });

  test('a platform with no mechanism offers recovery instead of silence',
      () async {
    // Silence is the failure the standard names; an offer costs one
    // dismissible affordance.
    final result = await DeferredEntryResolver(store: _Store(true)).onLaunch();
    expect(result.outcome, DeferredEntryOutcome.offerRecovery);
  });

  test('a mechanism that failed is a mechanism we do not have', () async {
    final result = await DeferredEntryResolver(
      store: _Store(true),
      source: _Source('ABC', throws: true),
    ).onLaunch();
    expect(result.outcome, DeferredEntryOutcome.offerRecovery);
  });

  group('the launch is marked once', () {
    test('after a recovery', () async {
      final store = _Store(true);
      final resolver =
          DeferredEntryResolver(store: store, source: _Source('ABC'));

      expect((await resolver.onLaunch()).outcome,
          DeferredEntryOutcome.recovered);
      // Recovering twice would reopen the same entry on a launch the viewer
      // never connected to it.
      expect((await resolver.onLaunch()).outcome, DeferredEntryOutcome.none);
      expect(store.marks, 1);
    });

    test('after an offer', () async {
      final store = _Store(true);
      final resolver = DeferredEntryResolver(store: store);

      expect((await resolver.onLaunch()).outcome,
          DeferredEntryOutcome.offerRecovery);
      // A recovery offered twice is a nag.
      expect((await resolver.onLaunch()).outcome, DeferredEntryOutcome.none);
    });
  });
}
