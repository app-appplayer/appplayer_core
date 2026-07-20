/// Method / event channel names for the `appplayer_core` Flutter plugin.
///
/// The Dart port implementations in this directory talk to the Android
/// (Kotlin) and iOS (Swift) native side over these channels. Desktop / web
/// have no native implementation; the ports catch `MissingPluginException`
/// and degrade to the NoOp behaviour.
library;

/// Single method channel carrying all request/response calls.
const String kMethodChannel = 'makemind.appplayer_core/methods';

/// Background wake events (BLE notify / push / fetch window) → `BackgroundWake`.
const String kWakesChannel = 'makemind.appplayer_core/wakes';

/// OS permission-status change notifications.
const String kPermissionChangesChannel =
    'makemind.appplayer_core/permission_changes';

/// Notification-tap events → the source app handle string.
const String kNotificationTapsChannel =
    'makemind.appplayer_core/notification_taps';
