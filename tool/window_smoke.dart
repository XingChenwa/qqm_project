// Exercises only a temporary desktop window: no Hive, credentials, or QQ calls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/services/desktop_window_controller.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/themes/app_theme.dart';
import 'package:qq_bot_manager/ui/widgets/desktop_window_frame.dart';
import 'package:qq_bot_manager/ui/widgets/window_close_dialog.dart';

class SmokeStorage extends StorageService {
  BotConfig config = BotConfig();
  @override
  BotConfig getBotConfig() => config;
  @override
  Future<void> saveBotConfig(BotConfig config) async =>
      this.config = BotConfig.fromMap(config.toMap());
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) exit(64);
  final steps = <String>[];
  final result = File('build/window-smoke-result.json');
  final shot = File('build/window-smoke-preview.png');
  final closeShot = File('build/close-dialog-smoke-preview.png');
  final boundary = GlobalKey();
  final navigatorKey = GlobalKey<NavigatorState>();
  final storage = SmokeStorage();
  var confirmations = 0;
  var finished = false;
  late final Timer deadline;
  Future<void> record(bool passed, String detail) async {
    if (finished) return;
    finished = true;
    deadline.cancel();
    await result.parent.create(recursive: true);
    await result.writeAsString(
      jsonEncode({'passed': passed, 'detail': detail, 'steps': steps}),
    );
  }

  Future<void> fail(String detail) async {
    await record(false, detail);
    try {
      await trayManager.destroy();
    } catch (_) {}
    exit(1);
  }

  deadline = Timer(const Duration(seconds: 30), () => fail('窗口/托盘自测超时'));
  final controller = DesktopWindowController(
    storage,
    confirmClose: () async {
      confirmations++;
      final future = showDialog<DesktopCloseDecision>(
        context: navigatorKey.currentContext!,
        builder: (_) => const WindowCloseDialog(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (confirmations == 1) {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await closeShot.writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      }
      steps.add('close-confirmation-$confirmations');
      navigatorKey.currentState!.pop(
        DesktopCloseDecision(hideToTray: true, remember: confirmations > 1),
      );
      return future;
    },
    beforeExit: () async {
      steps.add('exit-cleanup');
      await record(
        true,
        'frameless window, close confirmation, one-time tray, remembered preference, native close and explicit exit',
      );
    },
  );
  await controller.initialize();
  runApp(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: AppTheme.lightTheme,
        builder: (_, child) =>
            DesktopWindowFrame(controller: controller, child: child!),
        home: Scaffold(
          body: Center(
            child: Container(
              width: 480,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppTheme.lightDivider),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.desktop_windows_rounded,
                    size: 44,
                    color: AppTheme.qqBlue,
                  ),
                  SizedBox(height: 16),
                  Text(
                    '窗口与系统托盘自测',
                    style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 12),
                  Text(
                    '临时测试窗口 · 不读取机器人凭据 · 不连接 QQ',
                    style: TextStyle(color: AppTheme.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Future<void> waitFor(Future<bool> Function() check, String step) async {
    final until = DateTime.now().add(const Duration(seconds: 4));
    while (!await check()) {
      if (DateTime.now().isAfter(until)) throw StateError(step);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    steps.add(step);
  }

  try {
    if (!controller.ready || controller.trayReady) {
      throw StateError(controller.error);
    }
    steps.add('frameless-ready-no-forced-tray');
    if (!await windowManager.isPreventClose()) {
      throw StateError('native close not intercepted');
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await shot.writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
    await controller.toggleMaximize();
    await waitFor(windowManager.isMaximized, 'maximize');
    await controller.toggleMaximize();
    await waitFor(
      () async => !await windowManager.isMaximized(),
      'restore-maximize',
    );
    await controller.minimize();
    await waitFor(windowManager.isMinimized, 'minimize');
    await controller.showWindow();
    await waitFor(
      () async =>
          await windowManager.isVisible() && !await windowManager.isMinimized(),
      'restore-minimize',
    );
    await controller.requestClose();
    await waitFor(
      () async => !await windowManager.isVisible(),
      'custom-close-one-time-tray',
    );
    if (storage.config.closeToTray || storage.config.skipCloseConfirmation) {
      throw StateError('one-time choice must not be saved');
    }
    await controller.showWindow();
    await waitFor(windowManager.isVisible, 'tray-restore-window');
    await windowManager.close();
    await waitFor(
      () async => !await windowManager.isVisible(),
      'native-close-to-tray',
    );
    await controller.showWindow();
    await waitFor(windowManager.isVisible, 'native-close-restore');
    if (!storage.config.closeToTray || !storage.config.skipCloseConfirmation) {
      throw StateError('remembered tray choice not saved');
    }
    await windowManager.close();
    await waitFor(
      () async => !await windowManager.isVisible(),
      'remembered-native-close-no-prompt',
    );
    if (confirmations != 2) throw StateError('unexpected close confirmation');
    await controller.showWindow();
    await controller.exitApp();
    await Future<void>.delayed(const Duration(seconds: 2));
    // A real destroy should have ended the native message loop already.
    exit(2);
  } catch (error) {
    await fail(error.toString());
  }
}
