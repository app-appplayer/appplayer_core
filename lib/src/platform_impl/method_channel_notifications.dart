/// Native notification port (FR-NOTIF) over a method + event channel.
///
/// Backed by the plugin's Android `NotificationManager` and iOS
/// `UNUserNotificationCenter`. Without a native implementation posts are
/// dropped and permission reads as granted (the NoOp behaviour).
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../logging/logger.dart';
import '../notification/notification_port.dart';
import '../permission/platform_permission_port.dart';
import '../session/app_handle.dart';
import 'platform_channels.dart';

class MethodChannelAppNotificationPort implements AppNotificationPort {
  MethodChannelAppNotificationPort({
    MethodChannel? methods,
    EventChannel? taps,
    Logger? logger,
  })  : _methods = methods ?? const MethodChannel(kMethodChannel),
        _tapsChannel = taps ?? const EventChannel(kNotificationTapsChannel),
        _logger = logger ?? NoopLogger();

  final MethodChannel _methods;
  final EventChannel _tapsChannel;
  final Logger _logger;

  Stream<AppHandle>? _taps;

  @override
  Future<PermissionStatus> permissionStatus() async {
    try {
      final raw =
          await _methods.invokeMethod<String>('notification.permissionStatus');
      return _statusFrom(raw);
    } on MissingPluginException {
      return PermissionStatus.granted;
    } on PlatformException catch (e) {
      _logger.warn('notification.permissionStatus.failed', {'code': e.code});
      return PermissionStatus.denied;
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    try {
      final raw = await _methods
          .invokeMethod<String>('notification.requestPermission');
      return _statusFrom(raw);
    } on MissingPluginException {
      return PermissionStatus.granted;
    } on PlatformException catch (e) {
      _logger.warn('notification.requestPermission.failed', {'code': e.code});
      return PermissionStatus.denied;
    }
  }

  @override
  Future<void> post(AppNotification notification) async {
    try {
      await _methods.invokeMethod<void>('notification.post', {
        'id': notification.id,
        'title': notification.title,
        'body': notification.body,
        'source': notification.source.toString(),
      });
    } on MissingPluginException {
      // no native notifications — drop
    } on PlatformException catch (e) {
      _logger.warn('notification.post.failed', {
        'id': notification.id,
        'code': e.code,
      });
    }
  }

  @override
  Future<void> cancel(String id) async {
    try {
      await _methods.invokeMethod<void>('notification.cancel', {'id': id});
    } on MissingPluginException {
      // nothing to cancel
    } on PlatformException catch (e) {
      _logger.warn('notification.cancel.failed', {'id': id, 'code': e.code});
    }
  }

  @override
  Stream<AppHandle> get taps => _taps ??= _tapsChannel
      .receiveBroadcastStream()
      .map((e) => _decodeHandle(e as String))
      .where((h) => h != null)
      .cast<AppHandle>();

  AppHandle? _decodeHandle(String raw) {
    // Format is "source:key" produced by AppHandle.toString().
    final sep = raw.indexOf(':');
    if (sep <= 0) return null;
    final source = raw.substring(0, sep);
    final key = raw.substring(sep + 1);
    switch (source) {
      case 'server':
        return AppHandle.server(key);
      case 'bundle':
        return AppHandle.bundle(key);
      default:
        return null;
    }
  }

  PermissionStatus _statusFrom(String? name) {
    switch (name) {
      case 'granted':
        return PermissionStatus.granted;
      case 'denied':
        return PermissionStatus.denied;
      case 'restricted':
        return PermissionStatus.restricted;
      case 'notDetermined':
      default:
        return PermissionStatus.notDetermined;
    }
  }
}
