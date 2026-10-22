import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // A record/browser child has no tray or bot service to keep alive.
    return ProcessInfo.processInfo.environment["QQM_AUXILIARY_WINDOW"] != nil
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
