import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // FCM / локальные уведомления: проброс APNs-токена и баннеров.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
      registerChatReplyCategory()
    }
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    UIDevice.current.isProximityMonitoringEnabled = false
    super.applicationDidEnterBackground(application)
  }

  private func registerChatReplyCategory() {
    let reply = UNTextInputNotificationAction(
      identifier: "familychat_reply",
      title: "Ответить",
      options: [],
      textInputButtonTitle: "Отправить",
      textInputPlaceholder: "Сообщение"
    )
    let category = UNNotificationCategory(
      identifier: "familychat_message",
      actions: [reply],
      intentIdentifiers: [],
      hiddenPreviewsBodyPlaceholder: "Сообщение",
      options: [.hiddenPreviewsShowTitle]
    )
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let textResponse = response as? UNTextInputNotificationResponse,
       response.actionIdentifier == "familychat_reply",
       response.notification.request.trigger is UNPushNotificationTrigger {
      let info = response.notification.request.content.userInfo
      var payload: [String: String] = ["text": textResponse.userText]
      func value(_ key: String) -> String? {
        if let v = info[key] { return "\(v)" }
        if let nested = info["data"] as? [AnyHashable: Any], let v = nested[key] {
          return "\(v)"
        }
        if let v = info["gcm.notification.\(key)"] { return "\(v)" }
        return nil
      }
      if let threadId = value("thread_id") {
        payload["thread_id"] = threadId
      }
      UserDefaults.standard.set(payload, forKey: "familychat_pending_push_reply")
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FamilyChatCallProximity")!
    let proximityChannel = FlutterMethodChannel(
      name: "com.familychat/call_proximity",
      binaryMessenger: registrar.messenger()
    )
    proximityChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "enable":
        UIDevice.current.isProximityMonitoringEnabled = true
        result(nil)
      case "disable":
        UIDevice.current.isProximityMonitoringEnabled = false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let replyChannel = FlutterMethodChannel(
      name: "com.familychat/push_reply",
      binaryMessenger: registrar.messenger()
    )
    replyChannel.setMethodCallHandler { call, result in
      guard call.method == "takePending" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let pending = UserDefaults.standard.dictionary(forKey: "familychat_pending_push_reply")
      UserDefaults.standard.removeObject(forKey: "familychat_pending_push_reply")
      result(pending)
    }
  }
}
