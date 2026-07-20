/// Default platform-port selection (FR-PLATFORM).
///
/// Mobile (Android / iOS) — where the OS suspends the process and background
/// continuity actually matters — gets the native method-channel ports. Desktop
/// has no process-suspension model, so it keeps the NoOp ports (foreground
/// behaviour is identical either way). A host may still inject its own port
/// through `AppPlayerCoreService.initialize` to override this.
library;

import 'dart:io' show Platform;

import '../background/background_execution_port.dart';
import '../logging/logger.dart';
import '../notification/notification_port.dart';
import '../permission/platform_permission_port.dart';
import 'method_channel_background.dart';
import 'method_channel_notifications.dart';
import 'method_channel_permissions.dart';

bool get _isMobile => Platform.isAndroid || Platform.isIOS;

BackgroundExecutionPort defaultBackgroundPort({Logger? logger}) => _isMobile
    ? MethodChannelBackgroundExecutionPort(logger: logger)
    : const NoOpBackgroundExecutionPort();

PlatformPermissionPort defaultPermissionPort({Logger? logger}) => _isMobile
    ? MethodChannelPlatformPermissionPort(logger: logger)
    : const NoOpPlatformPermissionPort();

AppNotificationPort defaultNotificationPort({Logger? logger}) => _isMobile
    ? MethodChannelAppNotificationPort(logger: logger)
    : const NoOpNotificationPort();
