import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:qq_bot_manager/app.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/services/desktop_window_controller.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/settings_screen.dart';
import 'package:qq_bot_manager/ui/widgets/desktop_window_frame.dart';
import 'package:qq_bot_manager/ui/widgets/window_close_dialog.dart';

import 'support/fakes.dart';
import 'websocket_service_test.dart' show until;

class FailingClosePreferenceStorage extends MemoryStorage {
  @override
  Future<void> saveBotConfig(BotConfig config) async =>
      throw StateError('模拟关闭偏好保存失败');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  const trayChannel = MethodChannel('tray_manager');
  late List<String> calls;
  late List<MethodCall> trayCalls;
  late bool nativeMaximized;
  late bool nativeMinimized;
  late bool visible;
  late bool trayAvailable;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    calls = [];
    trayCalls = [];
    nativeMaximized = false;
    nativeMinimized = false;
    visible = true;
    trayAvailable = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
          calls.add('window:${call.method}');
          switch (call.method) {
            case 'isMaximized':
              return nativeMaximized;
            case 'isMinimized':
              return nativeMinimized;
            case 'isFullScreen':
              return false;
            case 'maximize':
              nativeMaximized = true;
            case 'unmaximize':
              nativeMaximized = false;
            case 'minimize':
              nativeMinimized = true;
            case 'restore':
              nativeMinimized = false;
            case 'hide':
              visible = false;
            case 'show':
              visible = true;
            case 'destroy':
            case 'close':
              visible = false;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trayChannel, (call) async {
          calls.add('tray:${call.method}');
          trayCalls.add(call);
          if (call.method == 'getBounds') {
            return trayAvailable
                ? {'x': 0.0, 'y': 0.0, 'width': 24.0, 'height': 24.0}
                : null;
          }
          return true;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trayChannel, null);
  });

  test('新旧配置默认询问关闭方式，不强制托盘，记住的偏好可以持久保存', () {
    expect(BotConfig.fromMap({}).closeToTray, isFalse);
    expect(BotConfig.fromMap({}).skipCloseConfirmation, isFalse);
    expect(
      BotConfig.fromMap(BotConfig(closeToTray: true).toMap()).closeToTray,
      isTrue,
    );
    expect(
      BotConfig.fromMap(
        BotConfig(skipCloseConfirmation: true).toMap(),
      ).skipCloseConfirmation,
      isTrue,
    );
  });

  test('未开启托盘时确认退出才关闭，并先完成退出清理，不建立托盘图标', () async {
    var cleanupCount = 0;
    var confirmations = 0;
    final controller = DesktopWindowController(
      MemoryStorage(),
      supported: true,
      confirmClose: () async {
        confirmations++;
        return const DesktopCloseDecision(hideToTray: false);
      },
      beforeExit: () async {
        cleanupCount++;
        calls.add('cleanup');
      },
    );
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(confirmations, 1);
    expect(cleanupCount, 1);
    expect(calls.indexOf('cleanup'), lessThan(calls.indexOf('window:close')));
    expect(calls, isNot(contains('window:hide')));
    expect(trayCalls, isEmpty);
    expect(visible, isFalse);
  });

  test('取消关闭或界面尚未就绪均保持可见，不保存偏好也不退出', () async {
    final storage = MemoryStorage();
    final controller = DesktopWindowController(storage, supported: true);
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(controller.error, contains('关闭确认尚未就绪'));
    controller.confirmClose = () async => null;
    await controller.requestClose();
    expect(visible, isTrue);
    expect(calls, isNot(contains('window:close')));
    expect(trayCalls, isEmpty);
    expect(storage.config.closeToTray, isFalse);
    expect(storage.config.skipCloseConfirmation, isFalse);
  });

  test('只隐藏本次不保存偏好，恢复后下次关闭仍会询问', () async {
    final storage = MemoryStorage();
    var confirmations = 0;
    final controller = DesktopWindowController(
      storage,
      supported: true,
      confirmClose: () async {
        confirmations++;
        return const DesktopCloseDecision(hideToTray: true);
      },
    );
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(controller.hiddenToTray, isTrue);
    expect(visible, isFalse);
    expect(storage.config.closeToTray, isFalse);
    expect(storage.config.skipCloseConfirmation, isFalse);
    await controller.showWindow();
    expect(visible, isTrue);
    expect(controller.trayReady, isFalse);
    await controller.requestClose();
    expect(confirmations, 2);
    expect(controller.hiddenToTray, isTrue);
  });

  test('勾选记住隐藏后持久保存，重建窗口控制器不再询问', () async {
    final storage = MemoryStorage(config: validConfig());
    final controller = DesktopWindowController(
      storage,
      supported: true,
      confirmClose: () async =>
          const DesktopCloseDecision(hideToTray: true, remember: true),
    );
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(storage.config.closeToTray, isTrue);
    expect(storage.config.skipCloseConfirmation, isTrue);
    expect(storage.config.clientSecret, 'test-secret');
    expect(controller.hiddenToTray, isTrue);
    await controller.showWindow();
    final restarted = DesktopWindowController(
      storage,
      supported: true,
      confirmClose: () async => throw StateError('不应再次询问'),
    );
    addTearDown(restarted.dispose);
    await restarted.requestClose();
    expect(restarted.hiddenToTray, isTrue);
    expect(restarted.error, isEmpty);
  });

  test('勾选记住退出后重启直接退出，不再询问或建立托盘', () async {
    final storage = MemoryStorage();
    final controller = DesktopWindowController(
      storage,
      supported: true,
      confirmClose: () async =>
          const DesktopCloseDecision(hideToTray: false, remember: true),
    );
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(storage.config.closeToTray, isFalse);
    expect(storage.config.skipCloseConfirmation, isTrue);
    final restarted = DesktopWindowController(
      storage,
      supported: true,
      confirmClose: () async => throw StateError('不应再次询问'),
    );
    addTearDown(restarted.dispose);
    calls.clear();
    await restarted.requestClose();
    expect(calls, contains('window:close'));
    expect(trayCalls, isEmpty);
    expect(restarted.error, isEmpty);
  });

  test('连续点击关闭与 Alt+F4 只显示一次确认，取消后可以再次询问', () async {
    final decision = Completer<DesktopCloseDecision?>();
    var confirmations = 0;
    final controller = DesktopWindowController(
      MemoryStorage(),
      supported: true,
      confirmClose: () {
        confirmations++;
        return decision.future;
      },
    );
    addTearDown(controller.dispose);
    final closing = controller.requestClose();
    await until(() => confirmations == 1);
    controller.onWindowClose();
    await controller.requestClose();
    expect(confirmations, 1);
    decision.complete(null);
    await closing;
    controller.confirmClose = () async {
      confirmations++;
      return null;
    };
    await controller.requestClose();
    expect(confirmations, 2);
    expect(visible, isTrue);
  });

  test('临时托盘初始化失败不隐藏，也不会记住无效的关闭选择', () async {
    trayAvailable = false;
    final storage = MemoryStorage();
    final controller = DesktopWindowController(
      storage,
      supported: true,
      confirmClose: () async =>
          const DesktopCloseDecision(hideToTray: true, remember: true),
    );
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(visible, isTrue);
    expect(controller.error, contains('托盘暂不可用'));
    expect(storage.config.closeToTray, isFalse);
    expect(storage.config.skipCloseConfirmation, isFalse);
  });

  test('记住关闭选项保存失败时不退出或隐藏，仍可操作窗口', () async {
    final storage = FailingClosePreferenceStorage();
    final controller = DesktopWindowController(
      storage,
      supported: true,
      confirmClose: () async =>
          const DesktopCloseDecision(hideToTray: false, remember: true),
    );
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(controller.error, contains('关闭操作未完成'));
    expect(visible, isTrue);
    expect(calls, isNot(contains('window:close')));
    expect(calls, isNot(contains('window:hide')));
    expect(storage.config.skipCloseConfirmation, isFalse);
  });

  test('开启托盘后关闭只隐藏；点击图标恢复，退出菜单强制退出而不是再次隐藏', () async {
    var cleanupCount = 0;
    final controller = DesktopWindowController(
      MemoryStorage(config: BotConfig(closeToTray: true)),
      supported: true,
      confirmClose: () async => throw StateError('开启托盘后不应询问'),
      beforeExit: () async {
        cleanupCount++;
      },
    );
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(visible, isFalse);
    expect(controller.hiddenToTray, isTrue);
    expect(controller.trayReady, isTrue);
    expect(cleanupCount, 0);
    expect(calls, isNot(contains('window:close')));
    final menu = trayCalls
        .firstWhere((call) => call.method == 'setContextMenu')
        .arguments
        .toString();
    expect(menu, contains('显示窗口'));
    expect(menu, contains('退出程序'));
    controller.onTrayIconMouseDown();
    await until(() => visible && !controller.hiddenToTray);
    controller.onTrayMenuItemClick(tray.MenuItem(key: 'exit', label: '退出程序'));
    await until(() => calls.contains('window:close'));
    expect(cleanupCount, 1);
  });

  test('托盘不可用时保持窗口可见，不悄悄退出，也不把程序藏起来', () async {
    trayAvailable = false;
    final controller = DesktopWindowController(
      MemoryStorage(config: BotConfig(closeToTray: true)),
      supported: true,
    );
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(visible, isTrue);
    expect(controller.trayReady, isFalse);
    expect(controller.error, contains('托盘暂不可用'));
    expect(calls, isNot(contains('window:hide')));
    expect(calls, isNot(contains('window:close')));
  });

  test('关闭托盘选项先恢复已隐藏的窗口，再销毁托盘；之后正常退出', () async {
    final storage = MemoryStorage(config: BotConfig(closeToTray: true));
    final controller = DesktopWindowController(storage, supported: true)
      ..ready = true
      ..confirmClose = () async =>
          const DesktopCloseDecision(hideToTray: false);
    addTearDown(controller.dispose);
    await controller.requestClose();
    calls.clear();
    storage.config.closeToTray = false;
    await controller.refreshPreferences();
    expect(visible, isTrue);
    expect(controller.trayReady, isFalse);
    expect(
      calls.indexOf('window:show'),
      lessThan(calls.indexOf('tray:destroy')),
    );
    await controller.requestClose();
    expect(calls, contains('window:close'));
  });

  test('原生关闭事件与自定义关闭按钮遵循同一个用户偏好，重复关闭不重复初始化托盘', () async {
    final controller = DesktopWindowController(
      MemoryStorage(config: BotConfig(closeToTray: true)),
      supported: true,
    );
    addTearDown(controller.dispose);
    controller.onWindowClose();
    controller.onWindowClose();
    await until(() => controller.hiddenToTray);
    expect(trayCalls.where((call) => call.method == 'setIcon').length, 1);
    expect(calls.where((call) => call == 'window:hide').length, 1);
  });

  test('退出清理失败时不销毁窗口，可以看到提示并重试', () async {
    final controller = DesktopWindowController(
      MemoryStorage(),
      supported: true,
      confirmClose: () async => const DesktopCloseDecision(hideToTray: false),
      beforeExit: () async {
        throw StateError('模拟存储错误');
      },
    );
    addTearDown(controller.dispose);
    await controller.requestClose();
    expect(visible, isTrue);
    expect(calls, isNot(contains('window:close')));
    expect(controller.error, contains('退出未完成'));
  });

  test('移动端不初始化窗口、托盘或拦截关闭', () async {
    final controller = DesktopWindowController(
      MemoryStorage(),
      supported: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.requestClose();
    await controller.minimize();
    expect(calls, isEmpty);
    expect(controller.ready, isFalse);
  });

  testWidgets('自定义按钮、拖拽、双击最大化和还原都调用真实窗口接口', (tester) async {
    final controller = DesktopWindowController(MemoryStorage(), supported: true)
      ..ready = true
      ..confirmClose = () async =>
          const DesktopCloseDecision(hideToTray: false);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopWindowFrame(
          controller: controller,
          child: const Scaffold(body: Center(child: Text('内容'))),
        ),
      ),
    );
    expect(find.byTooltip('最小化'), findsOneWidget);
    expect(find.byTooltip('最大化'), findsOneWidget);
    expect(find.byTooltip('关闭窗口'), findsOneWidget);
    await tester.tap(find.byTooltip('最大化'));
    await tester.pumpAndSettle();
    expect(nativeMaximized, isTrue);
    expect(find.byTooltip('还原窗口'), findsOneWidget);
    final region = find.byKey(const ValueKey('window-drag-region'));
    await tester.tap(region);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tap(region);
    await tester.pumpAndSettle();
    expect(nativeMaximized, isFalse);
    await tester.drag(region, const Offset(55, 0));
    await tester.pumpAndSettle();
    expect(calls, contains('window:startDragging'));
    await tester.tap(find.byTooltip('最小化'));
    await tester.pumpAndSettle();
    expect(nativeMinimized, isTrue);
    await tester.tap(find.byTooltip('关闭窗口'));
    await tester.pumpAndSettle();
    expect(calls, contains('window:close'));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('窗口选项由用户开启保存，保存后初始化托盘，默认不强迫驻留', (tester) async {
    tester.view.physicalSize = const Size(960, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStorage();
    final bot = BotClient(storage, apiService: RecordingApi());
    final controller = DesktopWindowController(storage, supported: true)
      ..ready = true;
    addTearDown(bot.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<BotClient>.value(value: bot),
          ChangeNotifierProvider<DesktopWindowController>.value(
            value: controller,
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('close-to-tray-switch'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pump();
    await tester.ensureVisible(find.text('保存窗口设置'));
    await tester.tap(find.text('保存窗口设置'));
    await tester.pumpAndSettle();
    expect(storage.getBotConfig().closeToTray, isTrue);
    expect(controller.trayReady, isTrue);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final remember in [false, true]) {
    testWidgets('关闭弹窗可取消或隐藏，记住选择为 $remember，原生关闭也使用相同弹窗', (tester) async {
      tester.view.physicalSize = const Size(960, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final bot = BotClient(storage, apiService: RecordingApi());
      final plugins = PluginManager(storage);
      final controller = DesktopWindowController(storage, supported: true)
        ..ready = true;
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storage),
            ChangeNotifierProvider<BotClient>.value(value: bot),
            ChangeNotifierProvider<PluginManager>.value(value: plugins),
            ChangeNotifierProvider<DesktopWindowController>.value(
              value: controller,
            ),
          ],
          child: const QQBotManagerApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭窗口'));
      await tester.pumpAndSettle();
      expect(find.byType(WindowCloseDialog), findsOneWidget);
      expect(find.text('以后不再显示，记住本次选择'), findsOneWidget);
      expect(visible, isTrue);
      expect(calls, isNot(contains('window:close')));
      controller.onWindowClose();
      await tester.pumpAndSettle();
      expect(find.byType(WindowCloseDialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel-window-close')));
      await tester.pumpAndSettle();
      expect(find.byType(WindowCloseDialog), findsNothing);
      expect(visible, isTrue);
      expect(storage.config.skipCloseConfirmation, isFalse);
      controller.onWindowClose();
      await tester.pumpAndSettle();
      if (remember) {
        await tester.tap(find.byKey(const ValueKey('remember-close-choice')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('hide-from-close-dialog')));
      await tester.pumpAndSettle();
      expect(controller.hiddenToTray, isTrue);
      expect(visible, isFalse);
      expect(storage.config.closeToTray, remember);
      expect(storage.config.skipCloseConfirmation, remember);
      await controller.showWindow();
      controller.onWindowClose();
      await tester.pumpAndSettle();
      if (remember) {
        expect(find.byType(WindowCloseDialog), findsNothing);
        expect(visible, isFalse);
      } else {
        expect(find.byType(WindowCloseDialog), findsOneWidget);
        expect(visible, isTrue);
        await tester.tap(find.byKey(const ValueKey('cancel-window-close')));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('设置路由也能弹窗，记住隐藏后保存其他设置不覆盖关闭偏好', (tester) async {
    tester.view.physicalSize = const Size(960, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStorage();
    final bot = BotClient(storage, apiService: RecordingApi());
    final plugins = PluginManager(storage);
    final controller = DesktopWindowController(storage, supported: true)
      ..ready = true;
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<BotClient>.value(value: bot),
          ChangeNotifierProvider<PluginManager>.value(value: plugins),
          ChangeNotifierProvider<DesktopWindowController>.value(
            value: controller,
          ),
        ],
        child: const QQBotManagerApp(),
      ),
    );
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    controller.onWindowClose();
    await tester.pumpAndSettle();
    expect(find.byType(WindowCloseDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('remember-close-choice')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('hide-from-close-dialog')));
    await tester.pumpAndSettle();
    await controller.showWindow();
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('close-to-tray-switch'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.ensureVisible(find.text('保存连接设置'));
    await tester.tap(find.text('保存连接设置'));
    await tester.pumpAndSettle();
    expect(storage.config.closeToTray, isTrue);
    expect(storage.config.skipCloseConfirmation, isTrue);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('设置允许恢复已关闭的关闭确认，保存后生效', (tester) async {
    tester.view.physicalSize = const Size(960, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStorage(
      config: BotConfig(skipCloseConfirmation: true),
    );
    final bot = BotClient(storage, apiService: RecordingApi());
    addTearDown(bot.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<BotClient>.value(value: bot),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('恢复关闭确认（保存后生效）'));
    await tester.tap(find.text('恢复关闭确认（保存后生效）'));
    await tester.pump();
    await tester.ensureVisible(find.text('保存窗口设置'));
    await tester.tap(find.text('保存窗口设置'));
    await tester.pumpAndSettle();
    expect(storage.config.closeToTray, isFalse);
    expect(storage.config.skipCloseConfirmation, isFalse);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('最小桌面窗口含自定义标题栏仍能展示聊天输入和设置导航', (tester) async {
    tester.view.physicalSize = const Size(960, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStorage();
    final bot = BotClient(storage, apiService: RecordingApi());
    final plugins = PluginManager(storage);
    final controller = DesktopWindowController(storage, supported: true)
      ..ready = true;
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    addTearDown(controller.dispose);
    await bot.addSession('u', isGroup: false, name: '窗口测试用户');
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<BotClient>.value(value: bot),
          ChangeNotifierProvider<PluginManager>.value(value: plugins),
          ChangeNotifierProvider<DesktopWindowController>.value(
            value: controller,
          ),
        ],
        child: const QQBotManagerApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopWindowFrame), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);
    expect(find.byTooltip('关闭窗口'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
