import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FamilyChatCallProximity")!
    let channel = FlutterMethodChannel(
      name: "com.familychat/call_proximity",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
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
  }
}
