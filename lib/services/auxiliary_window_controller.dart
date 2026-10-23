import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../utils/platforms.dart';
import 'desktop_window_chrome.dart';

/// Controls only this separate process's window. No bot/storage/tray is opened,
/// and closing a reader/browser never hides or exits the main application.
class AuxiliaryWindowController extends DesktopWindowChrome
    with WindowListener {
  final bool supported;
  @override
  bool ready = false;
  @override
  bool maximized = false;
  @override
  String error = '';
  bool _disposed = false;
  bool _closing = false;

  AuxiliaryWindowController({bool? supported})
    : supported = supported ?? isDesktopPlatform;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize({required String title, required Size size}) async {
    if (!supported || ready || _disposed) return;
    windowManager.addListener(this);
    try {
      await windowManager.ensureInitialized();
      await windowManager.waitUntilReadyToShow(
        WindowOptions(
          title: title,
          size: size,
          minimumSize: const Size(420, 420),
          center: true,
          titleBarStyle: TitleBarStyle.hidden,
          windowButtonVisibility: false,
          skipTaskbar: false,
        ),
      );
      await windowManager.setAsFrameless();
      await windowManager.setPreventClose(false);
      maximized = await windowManager.isMaximized();
      ready = true;
    } catch (_) {
      error = '自定义窗口初始化失败，已保留系统窗口操作';
      try {
        await windowManager.setPreventClose(false);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      } catch (_) {}
    }
    await _operate(() async {
      await windowManager.show();
      await windowManager.focus();
    });
    _changed();
  }

  Future<void> _operate(Future<void> Function() operation) async {
    if (!supported || _disposed || _closing) return;
    try {
      await operation();
    } catch (_) {
      error = '窗口操作未完成，请重试';
      _changed();
    }
  }

  @override
  Future<void> minimize() => _operate(windowManager.minimize);
  @override
  Future<void> drag() => _operate(windowManager.startDragging);
  @override
  Future<void> toggleMaximize() => _operate(() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
      maximized = false;
    } else {
      await windowManager.maximize();
      maximized = true;
    }
    _changed();
  });

  @override
  Future<void> requestClose() async {
    if (!supported || _disposed || _closing) return;
    _closing = true;
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {
      _closing = false;
      error = '关闭窗口未完成，请重试';
      _changed();
    }
  }

  @override
  void onWindowMaximize() {
    maximized = true;
    _changed();
  }

  @override
  void onWindowUnmaximize() {
    maximized = false;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    windowManager.removeListener(this);
    super.dispose();
  }
}
