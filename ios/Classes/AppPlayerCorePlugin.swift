import Flutter
import UIKit
import UserNotifications
import CoreLocation
import AVFoundation

/**
 * iOS side of the appplayer_core Platform Integration Foundation
 * (FR-PLATFORM): background execution (background task), OS permissions, and
 * notifications.
 */
public class AppPlayerCorePlugin: NSObject, FlutterPlugin,
    UNUserNotificationCenterDelegate {

  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  private let notifications = NotificationBridge()

  private var wakesSink: FlutterEventSink?
  private var notificationTapsSink: FlutterEventSink?

  // A tap that arrived before Dart subscribed to the taps stream; flushed when
  // the sink attaches.
  private var pendingTapSource: String?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let instance = AppPlayerCorePlugin()

    let methodChannel = FlutterMethodChannel(
      name: "makemind.appplayer_core/methods", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: methodChannel)

    FlutterEventChannel(name: "makemind.appplayer_core/wakes",
                        binaryMessenger: messenger)
      .setStreamHandler(WakesStreamHandler(instance))
    FlutterEventChannel(name: "makemind.appplayer_core/permission_changes",
                        binaryMessenger: messenger)
      .setStreamHandler(NoopStreamHandler())
    FlutterEventChannel(name: "makemind.appplayer_core/notification_taps",
                        binaryMessenger: messenger)
      .setStreamHandler(TapsStreamHandler(instance))

    // Receive notification taps so they can be routed back to the source app
    // (FR-NOTIF-004).
    UNUserNotificationCenter.current().delegate = instance
  }

  // MARK: - UNUserNotificationCenterDelegate

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let source =
      response.notification.request.content.userInfo["source"] as? String {
      if let sink = notificationTapsSink {
        sink(source)
      } else {
        pendingTapSource = source
      }
    }
    completionHandler()
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Show foreground notifications instead of suppressing them.
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "background.initialize":
      result(nil)
    case "background.begin":
      result(beginBackground())
    case "background.end":
      endBackground()
      result(nil)
    case "background.runJob":
      // iOS runs deferred work via BGTaskScheduler, registered by the host app
      // with its own identifiers. Acknowledge; the Dart scheduler reconciles on
      // the next foreground/wake pass.
      result(nil)
    case "permission.status":
      status(of: args["permission"] as? String, request: false, result: result)
    case "permission.request":
      status(of: args["permission"] as? String, request: true, result: result)
    case "notification.permissionStatus":
      notificationStatus(request: false, result: result)
    case "notification.requestPermission":
      notificationStatus(request: true, result: result)
    case "notification.post":
      notifications.post(
        id: args["id"] as? String ?? "",
        title: args["title"] as? String ?? "",
        body: args["body"] as? String ?? "",
        source: args["source"] as? String ?? "")
      result(nil)
    case "notification.cancel":
      notifications.cancel(id: args["id"] as? String ?? "")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Background execution

  private func beginBackground() -> Bool {
    endBackground()
    backgroundTaskId = UIApplication.shared.beginBackgroundTask(
      withName: "appplayer_core.background") { [weak self] in
      self?.endBackground()
    }
    return backgroundTaskId != .invalid
  }

  private func endBackground() {
    if backgroundTaskId != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTaskId)
      backgroundTaskId = .invalid
    }
  }

  // MARK: - Permissions

  private func status(of name: String?, request: Bool,
                      result: @escaping FlutterResult) {
    switch name {
    case "location":
      locationStatus(request: request, result: result)
    case "camera":
      mediaStatus(.video, request: request, result: result)
    case "microphone":
      mediaStatus(.audio, request: request, result: result)
    case "notifications":
      notificationStatus(request: request, result: result)
    default:
      // bluetooth (Info.plist backed), localNetwork, usb, backgroundExecution
      // have no simple gate on iOS — treated as granted.
      result("granted")
    }
  }

  private func locationStatus(request: Bool, result: @escaping FlutterResult) {
    let manager = CLLocationManager()
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = manager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    switch status {
    case .authorizedAlways, .authorizedWhenInUse:
      result("granted")
    case .denied:
      result("denied")
    case .restricted:
      result("restricted")
    case .notDetermined:
      if request { manager.requestWhenInUseAuthorization() }
      result("notDetermined")
    @unknown default:
      result("notDetermined")
    }
  }

  private func mediaStatus(_ type: AVMediaType, request: Bool,
                           result: @escaping FlutterResult) {
    let status = AVCaptureDevice.authorizationStatus(for: type)
    switch status {
    case .authorized: result("granted")
    case .denied: result("denied")
    case .restricted: result("restricted")
    case .notDetermined:
      if request {
        AVCaptureDevice.requestAccess(for: type) { granted in
          DispatchQueue.main.async { result(granted ? "granted" : "denied") }
        }
      } else {
        result("notDetermined")
      }
    @unknown default:
      result("notDetermined")
    }
  }

  private func notificationStatus(request: Bool, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    if request {
      center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        DispatchQueue.main.async { result(granted ? "granted" : "denied") }
      }
      return
    }
    center.getNotificationSettings { settings in
      let value: String
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral: value = "granted"
      case .denied: value = "denied"
      case .notDetermined: value = "notDetermined"
      @unknown default: value = "notDetermined"
      }
      DispatchQueue.main.async { result(value) }
    }
  }

  fileprivate func setWakesSink(_ sink: FlutterEventSink?) { wakesSink = sink }

  fileprivate func setTapsSink(_ sink: FlutterEventSink?) {
    notificationTapsSink = sink
    // Flush a tap captured before the stream was listened to.
    if let sink = sink, let pending = pendingTapSource {
      sink(pending)
      pendingTapSource = nil
    }
  }
}

// MARK: - Notification bridge

private class NotificationBridge {
  func post(id: String, title: String, body: String, source: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.userInfo = ["source": source]
    let request = UNNotificationRequest(
      identifier: id, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  func cancel(id: String) {
    UNUserNotificationCenter.current()
      .removePendingNotificationRequests(withIdentifiers: [id])
    UNUserNotificationCenter.current()
      .removeDeliveredNotifications(withIdentifiers: [id])
  }
}

// MARK: - Event stream handlers

private class WakesStreamHandler: NSObject, FlutterStreamHandler {
  private weak var plugin: AppPlayerCorePlugin?
  init(_ plugin: AppPlayerCorePlugin) { self.plugin = plugin }
  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    plugin?.setWakesSink(events); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    plugin?.setWakesSink(nil); return nil
  }
}

private class TapsStreamHandler: NSObject, FlutterStreamHandler {
  private weak var plugin: AppPlayerCorePlugin?
  init(_ plugin: AppPlayerCorePlugin) { self.plugin = plugin }
  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    plugin?.setTapsSink(events); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    plugin?.setTapsSink(nil); return nil
  }
}

private class NoopStreamHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? { nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}
