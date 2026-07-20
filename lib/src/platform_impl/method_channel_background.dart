/// Native background-execution port (FR-BGX) over a method + event channel.
///
/// Backed by the plugin's Android (foreground service / WorkManager) and iOS
/// (background task / BGTaskScheduler) code. On platforms without a native
/// implementation every call throws `MissingPluginException`, which is caught
/// here and degraded to the NoOp behaviour (nothing runs in the background).
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../background/background_execution_port.dart';
import '../background/background_policy.dart';
import '../logging/logger.dart';
import 'platform_channels.dart';

class MethodChannelBackgroundExecutionPort
    implements BackgroundExecutionPort {
  MethodChannelBackgroundExecutionPort({
    MethodChannel? methods,
    EventChannel? wakes,
    Logger? logger,
  })  : _methods = methods ?? const MethodChannel(kMethodChannel),
        _wakesChannel = wakes ?? const EventChannel(kWakesChannel),
        _logger = logger ?? NoopLogger();

  final MethodChannel _methods;
  final EventChannel _wakesChannel;
  final Logger _logger;

  bool _active = false;
  Stream<BackgroundWake>? _wakes;

  @override
  Future<void> initialize(BackgroundPolicy policy) async {
    try {
      await _methods.invokeMethod<void>(
        'background.initialize',
        {'policy': policy.name},
      );
    } on MissingPluginException {
      _logger.debug('background.initialize.no_native');
    } on PlatformException catch (e) {
      _logger.warn('background.initialize.failed', {'code': e.code});
    }
  }

  @override
  Future<bool> beginBackground() async {
    try {
      final granted =
          await _methods.invokeMethod<bool>('background.begin') ?? false;
      _active = granted;
      return granted;
    } on MissingPluginException {
      _active = false;
      return false;
    } on PlatformException catch (e) {
      _logger.warn('background.begin.failed', {'code': e.code});
      _active = false;
      return false;
    }
  }

  @override
  Future<void> endBackground() async {
    _active = false;
    try {
      await _methods.invokeMethod<void>('background.end');
    } on MissingPluginException {
      // no native — nothing to release
    } on PlatformException catch (e) {
      _logger.warn('background.end.failed', {'code': e.code});
    }
  }

  @override
  bool get isActive => _active;

  @override
  Stream<BackgroundWake> get wakes =>
      _wakes ??= _wakesChannel.receiveBroadcastStream().map(_decodeWake);

  @override
  Future<void> runBackgroundJob(String jobId) async {
    try {
      await _methods.invokeMethod<void>('background.runJob', {'jobId': jobId});
    } on MissingPluginException {
      // no native background task runner — skip until the next foreground tick
    } on PlatformException catch (e) {
      _logger.warn('background.runJob.failed', {'jobId': jobId, 'code': e.code});
    }
  }

  BackgroundWake _decodeWake(dynamic event) {
    final map = (event as Map).cast<String, dynamic>();
    return BackgroundWake(
      kind: _kindFrom(map['kind'] as String?),
      serverId: map['serverId'] as String?,
      jobId: map['jobId'] as String?,
    );
  }

  BackgroundWakeKind _kindFrom(String? name) {
    switch (name) {
      case 'bleNotify':
        return BackgroundWakeKind.bleNotify;
      case 'push':
        return BackgroundWakeKind.push;
      case 'fetchWindow':
      default:
        return BackgroundWakeKind.fetchWindow;
    }
  }
}
