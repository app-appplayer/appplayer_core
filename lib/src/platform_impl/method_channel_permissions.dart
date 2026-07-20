/// Native OS-permission port (FR-PERM) over a method + event channel.
///
/// Backed by the plugin's Android runtime-permission requests and iOS
/// framework authorization calls. Without a native implementation every call
/// degrades to `granted` (the NoOp behaviour) so desktop hosts are unaffected.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../logging/logger.dart';
import '../permission/platform_permission_port.dart';
import 'platform_channels.dart';

class MethodChannelPlatformPermissionPort
    implements PlatformPermissionPort {
  MethodChannelPlatformPermissionPort({
    MethodChannel? methods,
    EventChannel? changes,
    Logger? logger,
  })  : _methods = methods ?? const MethodChannel(kMethodChannel),
        _changesChannel =
            changes ?? const EventChannel(kPermissionChangesChannel),
        _logger = logger ?? NoopLogger();

  final MethodChannel _methods;
  final EventChannel _changesChannel;
  final Logger _logger;

  Stream<void>? _changes;

  @override
  Future<PermissionStatus> status(PlatformPermission permission) =>
      _call('permission.status', permission);

  @override
  Future<PermissionStatus> request(PlatformPermission permission) =>
      _call('permission.request', permission);

  @override
  Stream<void> get changes =>
      _changes ??= _changesChannel.receiveBroadcastStream().map((_) {});

  Future<PermissionStatus> _call(
    String method,
    PlatformPermission permission,
  ) async {
    try {
      final raw = await _methods.invokeMethod<String>(
        method,
        {'permission': permission.name},
      );
      return _statusFrom(raw);
    } on MissingPluginException {
      // Desktop / web without a permission model — treat as granted.
      return PermissionStatus.granted;
    } on PlatformException catch (e) {
      _logger.warn('permission.call.failed', {
        'method': method,
        'permission': permission.name,
        'code': e.code,
      });
      return PermissionStatus.denied;
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
