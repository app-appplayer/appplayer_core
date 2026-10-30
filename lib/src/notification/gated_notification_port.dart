/// The person's say over app notifications (platform spec 26 §3.5).
///
/// Wraps the host's port: an app the person has turned off is not shown, and
/// an app that posts faster than [maxPerWindow] in [window] is held to that —
/// the rest are dropped and [onThrottled] says so once per window, so the host
/// can offer to turn the app off. Everything else passes through, so the
/// native port keeps its capabilities (exact timing, channel declaration).
library;

import 'dart:async';

import '../permission/platform_permission_port.dart';
import '../session/app_handle.dart';
import 'notification_port.dart';

/// What a host lets the person decide about app notifications (spec 26 §3.5).
class NotificationPolicy {
  const NotificationPolicy({
    required this.isMuted,
    this.maxPerWindow = 20,
    this.window = const Duration(minutes: 1),
    this.onThrottled,
  });

  final bool Function(AppHandle app) isMuted;
  final int maxPerWindow;
  final Duration window;
  final void Function(AppHandle app)? onThrottled;
}

class GatedNotificationPort
    implements
        AppNotificationPort,
        ExactNotificationTiming,
        NotificationChannelDeclaration {
  GatedNotificationPort(
    this._inner, {
    required this.isMuted,
    this.maxPerWindow = 20,
    this.window = const Duration(minutes: 1),
    this.onThrottled,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final AppNotificationPort _inner;
  final DateTime Function() _now;

  /// True while the person has this app's notifications off.
  final bool Function(AppHandle app) isMuted;

  /// The most one app may post in [window]. A setting, not a rule: a host
  /// that wants none passes a large number.
  final int maxPerWindow;
  final Duration window;

  /// An app went over its limit; called once per window per app.
  final void Function(AppHandle app)? onThrottled;

  final Map<AppHandle, List<DateTime>> _recent = {};
  final Set<AppHandle> _told = {};

  @override
  Future<void> post(AppNotification notification) async {
    final app = notification.source;
    if (isMuted(app)) return;
    final now = _now();
    final cut = now.subtract(window);
    final seen = _recent.putIfAbsent(app, () => <DateTime>[])
      ..removeWhere((t) => !t.isAfter(cut));
    if (seen.length >= maxPerWindow) {
      if (_told.add(app)) onThrottled?.call(app);
      return;
    }
    if (seen.isEmpty) _told.remove(app);
    seen.add(now);
    await _inner.post(notification);
  }

  @override
  Future<void> declareChannels({
    required AppHandle source,
    required String appName,
    required List<AppNotificationChannel> channels,
  }) async {
    final inner = _inner;
    if (inner is NotificationChannelDeclaration) {
      await (inner as NotificationChannelDeclaration).declareChannels(
        source: source,
        appName: appName,
        channels: channels,
      );
    }
  }

  @override
  Future<bool> requestExactTiming() async {
    final inner = _inner;
    if (inner is ExactNotificationTiming) {
      return (inner as ExactNotificationTiming).requestExactTiming();
    }
    return true;
  }

  @override
  Future<PermissionStatus> permissionStatus() => _inner.permissionStatus();

  @override
  Future<PermissionStatus> requestPermission() => _inner.requestPermission();

  @override
  Future<void> cancel(String id) => _inner.cancel(id);

  @override
  Stream<AppHandle> get taps => _inner.taps;
}
