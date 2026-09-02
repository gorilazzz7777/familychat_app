import Flutter
import UIKit
import UserNotifications
import CallKit
import flutter_callkit_incoming
import Intents

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CallkitIncomingAppDelegate {
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

    let shareTargetsChannel = FlutterMethodChannel(
      name: "com.familychat/share_targets",
      binaryMessenger: registrar.messenger()
    )
    shareTargetsChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "syncShareShortcuts":
        if let chats = call.arguments as? [String: Any],
           let list = chats["chats"] as? [[String: Any]] {
          self.syncShareShortcuts(list)
        } else {
          self.syncShareShortcuts([])
        }
        result(nil)
      case "takePendingDirectShare":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func syncShareShortcuts(_ chats: [[String: Any]]) {
    guard #available(iOS 12.0, *) else { return }
    for chat in chats.prefix(4) {
      let threadId: Int? = {
        if let n = chat["thread_id"] as? Int { return n }
        if let s = chat["thread_id"] as? String { return Int(s) }
        return nil
      }()
      guard let threadId, threadId > 0 else { continue }
      let title = (chat["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let displayName = (title?.isEmpty == false) ? title! : "Чат"
      let handle = INPersonHandle(value: "\(threadId)", type: .unknown)
      let recipient = INPerson(
        personHandle: handle,
        nameComponents: nil,
        displayName: displayName,
        image: nil,
        contactIdentifier: nil,
        customIdentifier: "familychat_thread_\(threadId)"
      )
      let intent = INSendMessageIntent(
        recipients: [recipient],
        outgoingMessageType: .outgoingMessageText,
        content: nil,
        speakableGroupName: INSpeakableString(spokenPhrase: displayName),
        conversationIdentifier: "familychat_thread_\(threadId)",
        serviceName: "Family Space",
        sender: nil,
        attachments: nil
      )
      let interaction = INInteraction(intent: intent, response: nil)
      interaction.direction = .outgoing
      interaction.donate(completion: nil)
    }
  }

  func onAccept(_ call: Call, _ action: CXAnswerCallAction) {
    action.fulfill()
  }

  func onDecline(_ call: Call, _ action: CXEndCallAction) {
    action.fulfill()
  }

  func onEnd(_ call: Call, _ action: CXEndCallAction) {
    action.fulfill()
  }

  func onTimeOut(_ call: Call) {
  }
}
