import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../utils/platforms.dart';
import 'desktop_window_chrome.dart';
import 'storage_service.dart';

class DesktopCloseDecision {
  final bool hideToTray;
  final bool remember;

  const DesktopCloseDecision({required this.hideToTray, this.remember = false});
}

class DesktopWindowController extends DesktopWindowChrome
    with WindowListener, TrayListener {
  final StorageService storage;
  final bool supported;
  final Future<void> Function()? beforeExit;
  Future<DesktopCloseDecision?> Function()? confirmClose;
  @override
  bool ready = false;
  @override
  bool maximized = false;
  bool trayReady = false;
  bool hiddenToTray = false;
  @override
  String error = '';
  bool _disposed = false;
  bool _closing = false;
  bool _exiting = false;
  bool _oneTimeTray = false;
  Future<bool>? _trayInit;

  DesktopWindowController(
    this.storage, {
    bool? supported,
    this.beforeExit,
    this.confirmClose,
  }) : supported = supported ?? isDesktopPlatform;

  bool get closeToTray => storage.getBotConfig().closeToTray;
  bool get shouldConfirmClose =>
      !closeToTray && !storage.getBotConfig().skipCloseConfirmation;
  bool get _allowTray => closeToTray || _oneTimeTray;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (!supported || ready || _disposed) return;
    windowManager.addListener(this);
    trayManager.addListener(this);
    try {
      await windowManager.ensureInitialized();
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1280, 800),
          minimumSize: Size(960, 640),
          title: 'QQ 机器人管理器',
          center: true,
          titleBarStyle: TitleBarStyle.hidden,
          windowButtonVisibility: false,
          skipTaskbar: false,
        ),
      );
      await windowManager.setAsFrameless();
      await windowManager.setPreventClose(true);
      await windowManager.show();
      await windowManager.focus();
      ready = true;
      await refreshPreferences();
    } catch (_) {
      error = '自定义窗口初始化失败，已保留系统窗口操作';
      try {
        await windowManager.setPreventClose(false);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.show();
      } catch (_) {}
    }
    _changed();
  }

  Future<void> refreshPreferences() async {
    if (!supported || !ready || _disposed || _exiting) return;
    if (closeToTray) {
      await _ensureTray();
    } else {
      if (hiddenToTray) await showWindow();
      _oneTimeTray = false;
      if (trayReady) {
        await trayManager.destroy();
        trayReady = false;
      }
      error = '';
    }
    _changed();
  }

  Future<bool> _ensureTray() {
    if (trayReady && defaultTargetPlatform != TargetPlatform.windows) {
      return Future.value(true);
    }
    final pending = _trayInit;
    if (pending != null) return pending;
    final future = _createTray().whenComplete(() {
      _trayInit = null;
    });
    _trayInit = future;
    return future;
  }

  Future<bool> _createTray() async {
    try {
      final windows = defaultTargetPlatform == TargetPlatform.windows;
      if (trayReady) {
        if (!windows || await _validTrayBounds()) return true;
        trayReady = false;
        await trayManager.destroy();
      }
      final icon = windows
          ? 'assets/branding/tray.ico'
          : 'assets/branding/logo.png';
      await rootBundle.load(icon);
      await trayManager.setIcon(icon);
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '显示窗口'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '退出程序'),
          ],
        ),
      );
      if (defaultTargetPlatform != TargetPlatform.linux) {
        await trayManager.setToolTip('QQ 机器人管理器 · 点击显示窗口');
      }
      if (windows) {
        if (!await _validTrayBounds()) {
          throw StateError('系统托盘未就绪');
        }
      }
      if (_disposed || _exiting || !_allowTray) {
        await trayManager.destroy();
        return false;
      }
      trayReady = true;
      error = '';
      _changed();
      return true;
    } catch (_) {
      try {
        await trayManager.destroy();
      } catch (_) {}
      trayReady = false;
      error = '系统托盘暂不可用，窗口保持可见；可在设置中保存后重试';
      _changed();
      return false;
    }
  }

  Future<bool> _validTrayBounds() async {
    final bounds = await trayManager.getBounds();
    return bounds != null &&
        bounds.width.isFinite &&
        bounds.height.isFinite &&
        bounds.width > 0 &&
        bounds.height > 0 &&
        bounds.width <= 200 &&
        bounds.height <= 200;
  }

  Future<void> _operate(Future<void> Function() operation) async {
    if (!supported || _disposed || _exiting) return;
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

  Future<void> showWindow() => _operate(() async {
    await windowManager.setSkipTaskbar(false);
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
    hiddenToTray = false;
    if (_oneTimeTray && !closeToTray && trayReady) {
      await trayManager.destroy();
      trayReady = false;
    }
    _oneTimeTray = false;
    _changed();
  });

  @override
  Future<void> requestClose() async {
    if (!supported || _disposed || _closing || _exiting) return;
    _closing = true;
    try {
      var hideToTray = closeToTray;
      var remember = false;
      if (shouldConfirmClose) {
        final confirm = confirmClose;
        if (confirm == null) {
          error = '关闭确认尚未就绪，请稍后重试';
          _changed();
          return;
        }
        await showWindow();
        final decision = await confirm();
        if (decision == null || _disposed || _exiting) return;
        hideToTray = decision.hideToTray;
        remember = decision.remember;
      }
      if (!hideToTray) {
        if (remember) await _rememberCloseChoice(hideToTray: false);
        await exitApp();
      } else {
        _oneTimeTray = true;
        if (await _ensureTray()) {
          if (_disposed || _exiting || !_allowTray) return;
          if (remember) await _rememberCloseChoice(hideToTray: true);
          await windowManager.hide();
          hiddenToTray = true;
          _changed();
        } else {
          _oneTimeTray = false;
          await showWindow();
        }
      }
    } catch (_) {
      error = '关闭操作未完成，窗口保持可见，请重试';
      await showWindow();
      _changed();
    } finally {
      _closing = false;
    }
  }

  Future<void> _rememberCloseChoice({required bool hideToTray}) async {
    final config = storage.getBotConfig()
      ..closeToTray = hideToTray
      ..skipCloseConfirmation = true;
    await storage.saveBotConfig(config);
    _changed();
  }

  Future<void> exitApp() async {
    if (!supported || _disposed || _exiting) return;
    _exiting = true;
    try {
      await beforeExit?.call();
      try {
        if (trayReady) await trayManager.destroy();
      } catch (_) {}
      trayReady = false;
      await windowManager.setPreventClose(false);
      if (defaultTargetPlatform == TargetPlatform.windows) {
        // Use the normal WM_CLOSE lifecycle. The plugin's Windows destroy()
        // posts WM_QUIT and can tear down the engine before native callbacks.
        await windowManager.close();
      } else {
        await windowManager.destroy();
      }
    } catch (_) {
      _exiting = false;
      error = '退出未完成，请检查本地存储或重试';
      await showWindow();
      _changed();
    }
  }

  @override
  void onWindowClose() => unawaited(requestClose());
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
  void onTrayIconMouseDown() => unawaited(showWindow());
  @override
  void onTrayIconRightMouseDown() =>
      unawaited(_operate(trayManager.popUpContextMenu));
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') unawaited(showWindow());
    if (menuItem.key == 'exit') unawaited(exitApp());
  }

  @override
  void dispose() {
    _disposed = true;
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    if (trayReady) unawaited(trayManager.destroy().catchError((Object _) {}));
    super.dispose();
  }
}
