import Flutter
import UIKit
import UserNotifications
import CallKit
import AVFAudio
import BackgroundTasks
import flutter_callkit_incoming
import Intents
import Network
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CallkitIncomingAppDelegate {
  private static let outboxTaskId = "com.familychat.familychat_app.outboxRefresh"
  /// BGTaskScheduler allows only one launch-handler registration per id per process.
  private static var outboxBgTasksRegistered = false
  private var outboxChannel: FlutterMethodChannel?
  private var outboxBgTaskId: UIBackgroundTaskIdentifier = .invalid
  private var voiceProximityEventSink: FlutterEventSink?
  private var voiceProximityObserving = false
  private var voicePlaying = false
  private var voiceUseFrontSpeaker = false

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
    registerOutboxBgTasks()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    // Do NOT stop voice proximity here — bringing the phone to the ear blanks
    // the screen and can background the app; Dart owns stop when playback ends.
    NSLog("FamilyChatVoice: applicationDidEnterBackground proxObs=%@",
          voiceProximityObserving ? "1" : "0")
    if voiceProximityObserving {
      voiceProximityEventSink?(voiceAudioSnapshot(reason: "enterBackground"))
    }
    scheduleOutboxRefresh()
    super.applicationDidEnterBackground(application)
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    NSLog("FamilyChatVoice: applicationWillEnterForeground")
    if voiceProximityObserving {
      voiceProximityEventSink?(voiceAudioSnapshot(reason: "enterForeground"))
    }
    super.applicationWillEnterForeground(application)
  }

  private func registerOutboxBgTasks() {
    if #available(iOS 13.0, *) {
      guard !Self.outboxBgTasksRegistered else { return }
      Self.outboxBgTasksRegistered = true
      BGTaskScheduler.shared.register(
        forTaskWithIdentifier: Self.outboxTaskId,
        using: nil
      ) { task in
        self.handleOutboxRefresh(task: task as! BGAppRefreshTask)
      }
    }
  }

  private func scheduleOutboxRefresh() {
    if #available(iOS 13.0, *) {
      let request = BGAppRefreshTaskRequest(identifier: Self.outboxTaskId)
      request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
      do {
        try BGTaskScheduler.shared.submit(request)
      } catch {
        // Best-effort; system may deny under budget.
      }
    }
  }

  @available(iOS 13.0, *)
  private func handleOutboxRefresh(task: BGAppRefreshTask) {
    scheduleOutboxRefresh()
    var finished = false
    let finish: (Bool) -> Void = { success in
      guard !finished else { return }
      finished = true
      task.setTaskCompleted(success: success)
    }
    task.expirationHandler = {
      finish(false)
    }
    guard let channel = outboxChannel else {
      finish(false)
      return
    }
    channel.invokeMethod("flushOutbox", arguments: nil) { result in
      if result is FlutterError {
        finish(false)
      } else {
        finish(true)
      }
    }
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

    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

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
        // Keep monitoring if voice proximity is active.
        if !self.voiceProximityObserving {
          UIDevice.current.isProximityMonitoringEnabled = false
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let voiceProximityEvents = FlutterEventChannel(
      name: "com.familychat/voice_proximity_events",
      binaryMessenger: registrar.messenger()
    )
    voiceProximityEvents.setStreamHandler(VoiceProximityStreamHandler(appDelegate: self))

    let voiceProximityChannel = FlutterMethodChannel(
      name: "com.familychat/voice_proximity",
      binaryMessenger: registrar.messenger()
    )
    voiceProximityChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "start":
        result(self.startVoiceProximityMonitoring())
      case "stop":
        self.stopVoiceProximityMonitoring()
        result(nil)
      case "setEarpiece":
        self.setVoiceAudioRoute(earpiece: true)
        result(nil)
      case "setSpeaker":
        self.setVoiceAudioRoute(earpiece: false)
        result(nil)
      case "getSnapshot":
        result(self.voiceAudioSnapshot(reason: "getSnapshot"))
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

    // Services WebView: iOS 17+ HTTP CONNECT via WKWebsiteDataStore.proxyConfigurations
    // (Android uses ProxyController / WebView PROXY_OVERRIDE).
    let servicesProxyRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "FamilyChatServicesWebViewProxy"
    )!
    let servicesProxyChannel = FlutterMethodChannel(
      name: "com.familychat/services_webview_proxy",
      binaryMessenger: servicesProxyRegistrar.messenger()
    )
    servicesProxyChannel.setMethodCallHandler { call, result in
      ServicesWebViewProxy.handle(call, result: result)
    }

    let outboxRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "FamilyChatOutboxBackground")!
    let outboxChannel = FlutterMethodChannel(
      name: "com.familychat/outbox_background",
      binaryMessenger: outboxRegistrar.messenger()
    )
    self.outboxChannel = outboxChannel
    outboxChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "gone", message: nil, details: nil))
        return
      }
      switch call.method {
      case "register":
        self.registerOutboxBgTasks()
        result(nil)
      case "scheduleRefresh":
        self.scheduleOutboxRefresh()
        result(nil)
      case "begin":
        if self.outboxBgTaskId != .invalid {
          result(nil)
          return
        }
        self.outboxBgTaskId = UIApplication.shared.beginBackgroundTask(withName: "familychat.outbox") {
          if self.outboxBgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(self.outboxBgTaskId)
            self.outboxBgTaskId = .invalid
          }
        }
        result(nil)
      case "end":
        if self.outboxBgTaskId != .invalid {
          UIApplication.shared.endBackgroundTask(self.outboxBgTaskId)
          self.outboxBgTaskId = .invalid
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func syncShareShortcuts(_ chats: [[String: Any]]) {
    guard #available(iOS 14.0, *) else { return }

    INInteraction.delete(with: "familychat_share_shortcuts") { _ in
      for chat in chats.prefix(4) {
        let threadId: Int? = {
          if let n = chat["thread_id"] as? Int { return n }
          if let n = chat["thread_id"] as? NSNumber { return n.intValue }
          if let s = chat["thread_id"] as? String { return Int(s) }
          return nil
        }()
        guard let threadId, threadId > 0 else { continue }
        let title = (chat["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (title?.isEmpty == false) ? title! : "Чат"
        let conversationId = "familychat_thread_\(threadId)"
        let groupName = INSpeakableString(spokenPhrase: displayName)
        let intent = INSendMessageIntent(
          recipients: nil,
          outgoingMessageType: .outgoingMessageText,
          content: nil,
          speakableGroupName: groupName,
          conversationIdentifier: conversationId,
          serviceName: "Family Space",
          sender: nil,
          attachments: nil
        )
        if let icon = UIImage(named: "AppIcon") ?? UIImage(named: "ic_launcher") {
          if let data = icon.pngData() {
            intent.setImage(INImage(imageData: data), forParameterNamed: \.speakableGroupName)
          }
        }
        if #available(iOS 15.0, *) {
          let metadata = INSendMessageIntentDonationMetadata()
          metadata.recipientCount = 1
          metadata.mentionsCurrentUser = false
          metadata.isReplyToCurrentUser = false
          metadata.notifyRecipientAnyway = false
          intent.donationMetadata = metadata
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = conversationId
        interaction.groupIdentifier = "familychat_share_shortcuts"
        interaction.direction = .outgoing
        interaction.donate(completion: nil)
      }
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

  func didActivateAudioSession(_ audioSession: AVAudioSession) {
  }

  func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
  }

  fileprivate func startVoiceProximityMonitoring() -> Bool {
    // All modern iPhones expose proximity; simulator does not.
    #if targetEnvironment(simulator)
    return false
    #else
    if voiceProximityObserving { return true }
    UIDevice.current.isProximityMonitoringEnabled = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onProximityChanged),
      name: UIDevice.proximityStateDidChangeNotification,
      object: nil
    )
    voiceProximityObserving = true
    NSLog("FamilyChatVoice: startVoiceProximity observing")
    voiceProximityEventSink?(voiceAudioSnapshot(reason: "sensor_start"))
    return true
    #endif
  }

  fileprivate func setVoicePlaying(_ playing: Bool) {
    voicePlaying = playing
    NSLog("FamilyChatVoice: setVoicePlaying playing=%@", playing ? "1" : "0")
    if !playing {
      voiceUseFrontSpeaker = false
      UIDevice.current.isProximityMonitoringEnabled = false
      setVoiceAudioRoute(earpiece: false)
      voiceProximityEventSink?(voiceAudioSnapshot(reason: "playing_false"))
      return
    }
    #if !targetEnvironment(simulator)
    UIDevice.current.isProximityMonitoringEnabled = true
    #endif
    setVoiceAudioRoute(earpiece: false)
    evaluateVoiceRaiseToListen(reason: "playing_true")
  }

  fileprivate func stopVoiceProximityMonitoring() {
    voicePlaying = false
    voiceUseFrontSpeaker = false
    guard voiceProximityObserving else {
      UIDevice.current.isProximityMonitoringEnabled = false
      return
    }
    NSLog("FamilyChatVoice: stopVoiceProximity")
    NotificationCenter.default.removeObserver(
      self,
      name: UIDevice.proximityStateDidChangeNotification,
      object: nil
    )
    voiceProximityObserving = false
    UIDevice.current.isProximityMonitoringEnabled = false
    let session = AVAudioSession.sharedInstance()
    do {
      try session.overrideOutputAudioPort(.none)
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      // Best-effort restore.
    }
  }

  @objc private func onProximityChanged(_ notification: Notification) {
    let near = UIDevice.current.proximityState
    NSLog("FamilyChatVoice: proximity near=%@", near ? "1" : "0")
    evaluateVoiceRaiseToListen(reason: "sensor")
  }

  /// TG listen sense on iOS: while playing + proximity near → earpiece;
  /// far → speaker. Headset/BT forbids. Screen blank = system proximity.
  private func evaluateVoiceRaiseToListen(reason: String) {
    guard voicePlaying else { return }
    let headset = voiceHeadsetForbidden()
    let near = UIDevice.current.proximityState
    let wantFront = near && !headset
    applyVoiceWantFront(wantFront: wantFront, near: near, headset: headset, reason: reason)
  }

  private func applyVoiceWantFront(
    wantFront: Bool,
    near: Bool,
    headset: Bool,
    reason: String
  ) {
    if wantFront != voiceUseFrontSpeaker {
      NSLog(
        "FamilyChatVoice: raiseToListen front=%@ near=%@ headset=%@ why=%@",
        wantFront ? "1" : "0",
        near ? "1" : "0",
        headset ? "1" : "0",
        reason
      )
      setVoiceAudioRoute(earpiece: wantFront)
      voiceProximityEventSink?(voiceAudioSnapshot(reason: "route_change"))
    } else if reason != "sensor" {
      voiceProximityEventSink?(voiceAudioSnapshot(reason: reason))
    }
  }

  private func voiceHeadsetForbidden() -> Bool {
    let session = AVAudioSession.sharedInstance()
    for out in session.currentRoute.outputs {
      switch out.portType {
      case .headphones, .headsetMic, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
        return true
      default:
        continue
      }
    }
    return false
  }

  /// Speaker = playAndRecord+defaultToSpeaker; earpiece = playAndRecord without.
  /// Dart restarts the player after a flip (TG startAudioAgain).
  fileprivate func setVoiceAudioRoute(earpiece: Bool) {
    let session = AVAudioSession.sharedInstance()
    voiceUseFrontSpeaker = earpiece
    do {
      if earpiece {
        try session.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.allowBluetooth, .allowBluetoothA2DP]
        )
        try session.overrideOutputAudioPort(.none)
      } else {
        try session.setCategory(
          .playAndRecord,
          mode: .default,
          options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.overrideOutputAudioPort(.speaker)
      }
      try session.setActive(true)
      NSLog("FamilyChatVoice: setVoiceAudioRoute earpiece=%@", earpiece ? "1" : "0")
    } catch {
      NSLog("FamilyChatVoice: setVoiceAudioRoute fail %@", "\(error)")
    }
  }

  fileprivate func voiceAudioSnapshot(reason: String) -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
    let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
    return [
      "reason": reason,
      "near": UIDevice.current.proximityState,
      "wantFrontSpeaker": voiceUseFrontSpeaker,
      "playing": voicePlaying,
      "raised": UIDevice.current.proximityState,
      "headsetForbidden": voiceHeadsetForbidden(),
      "otherAudio": session.isOtherAudioPlaying,
      "secondaryAudio": session.secondaryAudioShouldBeSilencedHint,
      "proxObs": voiceProximityObserving,
    ]
  }

  fileprivate func setVoiceProximityEventSink(_ sink: FlutterEventSink?) {
    voiceProximityEventSink = sink
    if voiceProximityObserving, let sink = sink {
      sink(voiceAudioSnapshot(reason: "sink_listen"))
    }
  }
}

private final class VoiceProximityStreamHandler: NSObject, FlutterStreamHandler {
  private weak var appDelegate: AppDelegate?

  init(appDelegate: AppDelegate) {
    self.appDelegate = appDelegate
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    appDelegate?.setVoiceProximityEventSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    appDelegate?.setVoiceProximityEventSink(nil)
    return nil
  }
}

/// Bridges Dart Services WebView → WKWebsiteDataStore HTTP CONNECT proxy (iOS 17+).
/// Mirrors flutter_inappwebview 6.2 ProxyController iOS path without upgrading the plugin.
private enum ServicesWebViewProxy {
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      if #available(iOS 17.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "setProxy":
      guard #available(iOS 17.0, *) else {
        result(
          FlutterError(
            code: "unsupported",
            message: "iOS 17+ required for Services WebView proxy",
            details: nil
          )
        )
        return
      }
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "map required", details: nil))
        return
      }
      let host = (args["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !host.isEmpty else {
        result(FlutterError(code: "bad_args", message: "host required", details: nil))
        return
      }
      let portValue: Int
      if let p = args["port"] as? Int {
        portValue = p
      } else if let p = args["port"] as? NSNumber {
        portValue = p.intValue
      } else if let s = args["port"] as? String, let p = Int(s) {
        portValue = p
      } else {
        result(FlutterError(code: "bad_args", message: "port required", details: nil))
        return
      }
      guard portValue > 0, portValue <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
        result(FlutterError(code: "bad_args", message: "invalid port", details: nil))
        return
      }
      DispatchQueue.main.async {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        var config = ProxyConfiguration(httpCONNECTProxy: endpoint)
        // Do not fall back to direct — blocked sites would "succeed" as empty/fail in RU.
        config.allowFailover = false
        let configs = [config]
        WKWebsiteDataStore.default().proxyConfigurations = configs
        WKWebsiteDataStore.nonPersistent().proxyConfigurations = configs
        NSLog("FamilyChatServices: setProxy %@:%d", host, portValue)
        result(nil)
      }
    case "clearProxy":
      guard #available(iOS 17.0, *) else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        WKWebsiteDataStore.default().proxyConfigurations = []
        WKWebsiteDataStore.nonPersistent().proxyConfigurations = []
        NSLog("FamilyChatServices: clearProxy")
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
