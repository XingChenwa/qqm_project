import 'package:flutter/foundation.dart';

/// Shared chrome only. Main-window tray/preferences and auxiliary-window
/// lifecycles stay separate, even though they use the same title bar.
abstract class DesktopWindowChrome extends ChangeNotifier {
  bool get ready;
  bool get maximized;
  String get error;
  Future<void> minimize();
  Future<void> drag();
  Future<void> toggleMaximize();
  Future<void> requestClose();
}
