/// The 0.2.3 cut's public names, written the way a host writes them: through
/// the package barrel only. A name the CHANGELOG puts forward that the barrel
/// does not export fails to compile here, which a suite importing `src/`
/// cannot catch.
///
/// The cut adds only: a host written against 0.2.2 — its own notification
/// port, a catch of the loader's error around an entry — compiles and behaves
/// as before.
library;

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Visitor implements ServingHeaders {
  @override
  Future<Map<String, String>> headersFor(Uri endpoint) async =>
      <String, String>{'x-visitor': 'a'};
}

/// A host's own port as written against 0.2.2: no member to add.
class _HostPort implements AppNotificationPort {
  @override
  Future<PermissionStatus> permissionStatus() async => PermissionStatus.granted;

  @override
  Future<PermissionStatus> requestPermission() async =>
      PermissionStatus.granted;

  @override
  Future<void> post(AppNotification notification) async {}

  @override
  Future<void> cancel(String id) async {}

  @override
  Stream<AppHandle> get taps => const Stream<AppHandle>.empty();
}

class _TimedPort extends _HostPort implements ExactNotificationTiming {
  @override
  Future<bool> requestExactTiming() async => true;
}

void main() {
  test('the cut\'s names are reachable from the barrel', () async {
    final at = DateTime(2026, 10, 4, 12);
    final n = AppNotification(
      id: 'ticket.reminder',
      title: '2 min left',
      body: 'Buy more time or finish up.',
      source: const AppHandle.server('safepage.tickets'),
      at: at,
      expiresAt: at.add(const Duration(minutes: 2)),
    );
    expect(n.at, at);
    expect(n.expiresAt, isNotNull);
    final AppNotificationPort timed = _TimedPort();
    expect(_HostPort() is ExactNotificationTiming, isFalse);
    expect(timed is ExactNotificationTiming, isTrue);
    // The way a host asks: match for the capability on the port it holds.
    var asked = false;
    if (timed case final ExactNotificationTiming t) {
      asked = await t.requestExactTiming();
    }
    expect(asked, isTrue);
    expect(await _Visitor().headersFor(Uri.https('x')), {'x-visitor': 'a'});

    final missing = EntryTargetNotInstalled(EntryTargetKind.bundle, 'b.id');
    expect(missing.ref, 'b.id');
    // A 0.2.2 caller catching the loader's error keeps catching it.
    Object? caught;
    try {
      throw missing;
    } on BundleLoadException catch (e) {
      caught = e;
    }
    expect((caught as BundleLoadException?)?.reason, BundleLoadReason.notFound);

    const labels = EntryChromeLabels(verified: 'Checked', guest: 'Visitor');
    expect(labels.guest, 'Visitor');
    final Type frame = EntryFrame;
    final Type message = EntryMessage;
    final Type leave = EntryLeaveScreen;
    final Type support = EntrySupport;
    expect(<Type>[frame, message, leave, support], hasLength(4));
    expect(const SizedBox(), isA<Widget>());
  });
}
