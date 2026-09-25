/// Implemented by a connect error that already knows the endpoint is not there
/// right now, and that something will say when it is back — a lending device
/// that is offline, whose return the account's presence announces.
///
/// The connection layer then stops treating an open app as a reason to dial
/// every second: no timer can succeed before that signal, and each failed dial
/// wakes every lifecycle listener. The host turns the signal into
/// `AppPlayerCoreService.hintReachable` (FR-HEALTH-008, FR-HEALTH-011).
abstract interface class AwaitsReachability {}
