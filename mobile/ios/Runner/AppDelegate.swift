import Flutter
import UIKit
import UserNotifications

/// Bridges APNs enrollment and opaque notification targets into the shared Flutter session.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?
  private var registrationResult: FlutterResult?
  // A cold-start tap can arrive before the Flutter channel exists; retain only its navigation target.
  private var openedNotification: [String: String]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // APNs is an OS service; no Firebase SDK or third-party analytics is required on Apple devices.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Register after the implicit engine is ready, when its messenger and plugin registry are available.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "bloodconnection/apns",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    pushChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "register":
        // Complete an older pending callback before replacement so its Dart Future is not stranded.
        self.registrationResult?(FlutterError(code: "superseded", message: "Registration restarted", details: nil))
        self.registrationResult = result
        UIApplication.shared.registerForRemoteNotifications()
      case "unregister":
        UIApplication.shared.unregisterForRemoteNotifications()
        self.openedNotification = nil
        result(nil)
      case "initialNotification":
        result(self.openedNotification)
        self.openedNotification = nil
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(_ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    // Only the authenticated API receives this token; it is never written to device logs.
    registrationResult?(deviceToken.map { String(format: "%02x", $0) }.joined())
    registrationResult = nil
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(_ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error) {
    registrationResult?(FlutterError(code: "apns_unavailable",
      message: "Apple notification registration is unavailable. Check signing and Push Notifications capability.", details: nil))
    registrationResult = nil
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  /// Forwards a private notification tap for authenticated review on the phone.
  ///
  /// Dart validates bounded IDs before navigation; the API still authorizes the
  /// referenced record. A watch action cannot accept a donation on the lock screen.
  func openPrivateNotification(_ response: UNNotificationResponse) -> Bool {
    let info = response.notification.request.content.userInfo
    var payload: [String: String]
    // Forward only opaque navigation targets. Review notes and private report contents stay inside the API.
    if let reportID = info["report_id"] as? String, let country = info["report_country"] as? String {
      payload = ["report_id": reportID, "report_country": country]
    } else if let requestID = info["request_id"] as? String {
      payload = ["request_id": requestID]
    } else { return false }
    openedNotification = payload
    pushChannel?.invokeMethod("opened", arguments: payload)
    return true
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    if openPrivateNotification(response) { completionHandler() }
    else { super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler) }
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if notification.request.content.userInfo["request_id"] != nil || notification.request.content.userInfo["report_id"] != nil {
      if #available(iOS 14.0, *) { completionHandler([.banner, .sound]) }
      else { completionHandler([.alert, .sound]) }
    } else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
  }
}
