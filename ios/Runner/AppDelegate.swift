import Flutter
import UIKit
import UserNotifications

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "QQMUpdates") {
      QQMUpdates.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "QQMNotifications") {
      QQMNotifications.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "QQMBackgroundHelp") {
      QQMBackgroundHelp.register(with: registrar)
    }
  }
}

/// Open the user's app settings only. iOS does not offer a setting that makes
/// an arbitrary bot WebSocket run forever, so no fake background mode is added.
final class QQMBackgroundHelp: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "cn.uuze.botmanager/background", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(QQMBackgroundHelp(), channel: channel)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "openSettings" else { result(FlutterMethodNotImplemented); return }
    guard let url = URL(string: UIApplication.openSettingsURLString) else { result(nil); return }
    UIApplication.shared.open(url) { _ in result(nil) }
  }
}

/// Immediate local notifications. No APNs entitlement or fabricated background
/// mode is requested; iOS can suspend the gateway when the app is backgrounded.
final class QQMNotifications: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  private let channel: FlutterMethodChannel
  private var pendingLaunch: String?
  init(channel: FlutterMethodChannel) { self.channel = channel; super.init() }
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "cn.uuze.botmanager/notifications", binaryMessenger: registrar.messenger())
    let plugin = QQMNotifications(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    UNUserNotificationCenter.current().delegate = plugin
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "isAllowed":
      center.getNotificationSettings { settings in
        DispatchQueue.main.async { result(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) }
      }
    case "requestPermission":
      center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in DispatchQueue.main.async { result(granted) } }
    case "consumeLaunch": result(pendingLaunch); pendingLaunch = nil
    case "cancelAll": center.removeAllDeliveredNotifications(); center.removeAllPendingNotificationRequests(); result(nil)
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else { result(nil); return }
      UIApplication.shared.open(url) { _ in result(nil) }
    case "show":
      guard let args = call.arguments as? [String: Any], let id = args["id"] as? NSNumber,
            let payload = args["payload"] as? String, payload.count <= 8192 else {
        result(FlutterError(code: "NOTIFICATION_INVALID", message: "通知参数无效", details: nil)); return
      }
      let content = UNMutableNotificationContent()
      content.title = String((args["title"] as? String ?? "QQ机器人管理器").prefix(200))
      content.body = String((args["body"] as? String ?? "").prefix(1000))
      content.sound = .default
      content.threadIdentifier = args["thread"] as? String ?? "qqm"
      content.userInfo = ["qqm_notification": payload]
      center.add(UNNotificationRequest(identifier: id.stringValue, content: content, trigger: nil)) { error in
        DispatchQueue.main.async { result(error == nil ? nil : FlutterError(code: "NOTIFICATION_FAILED", message: "系统通知发送失败", details: nil)) }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if #available(iOS 14.0, *) { completionHandler([.banner, .list, .sound]) }
    else { completionHandler([.alert, .sound]) }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    if let payload = response.notification.request.content.userInfo["qqm_notification"] as? String {
      pendingLaunch = payload
      DispatchQueue.main.async { self.channel.invokeMethod("opened", arguments: payload) }
    }
    completionHandler()
  }
}

/// iOS does not permit installing an unsigned IPA from another app.
/// Export to Files/a user-selected signing tool instead of claiming installation.
final class QQMUpdates: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "cn.uuze.botmanager/updates", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(QQMUpdates(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "shareIpa" else { result(FlutterMethodNotImplemented); return }
    guard let arguments = call.arguments as? [String: Any], let path = arguments["path"] as? String,
          let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      result(FlutterError(code: "SHARE_FAILED", message: "缺少更新文件路径", details: nil)); return
    }
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let allowed = support.appendingPathComponent("updates", isDirectory: true).resolvingSymlinksInPath().path + "/"
    guard file.path.hasPrefix(allowed), file.pathExtension == "ipa", FileManager.default.fileExists(atPath: file.path) else {
      result(FlutterError(code: "SHARE_FAILED", message: "只能导出本应用已校验的 IPA 更新缓存", details: nil)); return
    }
    guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
          var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      result(FlutterError(code: "SHARE_FAILED", message: "当前没有可显示导出界面的窗口", details: nil)); return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = presenter.view
    sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
    presenter.present(sheet, animated: true) { result(nil) }
  }
}
