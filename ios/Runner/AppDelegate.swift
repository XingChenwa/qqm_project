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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "QQMUpdates") {
      QQMUpdates.register(with: registrar)
    }
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
