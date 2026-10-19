import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'package:qq_bot_manager/ui/widgets/markdown_workbench.dart';
import 'package:qq_bot_manager/ui/widgets/mobile_workspace.dart';

import 'connection_ui_test.dart' show captureUi;
import 'mobile_and_group_commands_test.dart' show appShell;
import 'support/fakes.dart';
import 'support/ui_actions.dart';

class DarkMemoryStorage extends MemoryStorage {
  @override
  bool getThemeMode() => true;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (Platform.environment['QQM_CAPTURE_UI'] == '1' && Platform.isWindows) {
      await (FontLoader('Microsoft YaHei')..addFont(
            File(
              'C:/Windows/Fonts/msyh.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      for (final family in [
        'Ahem',
        'Roboto',
        'CupertinoSystemText',
        'CupertinoSystemDisplay',
        'Consolas',
      ]) {
        await (FontLoader(family)..addFont(
              File(
                'C:/Windows/Fonts/msyh.ttc',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      }
    }
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final size in [
      const Size(320, 740),
      const Size(390, 844),
      const Size(844, 390),
    ]) {
      testWidgets('${platform.name} 手机重设计 ${size.width}：导航、工具、Markdown、键盘和设置', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final storage = MemoryStorage();
        final api = RecordingApi();
        final bot = BotClient(storage, apiService: api);
        final plugins = PluginManager(storage);
        addTearDown(bot.dispose);
        addTearDown(plugins.dispose);
        await tester.runAsync(() => plugins.init());
        await bot.addSession('design-group', name: '机器人开发交流群', isGroup: true);
        await bot.addSession('design-user', name: '小林', isGroup: false);
        for (final item in [
          ('m1', '早上好！今天的天气怎么样？', false),
          ('m2', '北京今天晴，适合出门走走 ☀', true),
          ('m3', '收到，顺便试试新版的聊天界面。', false),
        ]) {
          await storage.saveMessage(
            MessageModel(
              id: item.$1,
              sessionId: 'design-group',
              senderId: item.$3 ? 'bot' : 'member',
              senderName: item.$3 ? '机器人' : '小林',
              content: item.$2,
              messageType: 0,
              timestamp: DateTime(2026, 10, 19, 10, 30),
              isFromBot: item.$3,
            ),
          );
        }
        await storage.updateSessionLastMessage(
          'design-group',
          '收到，顺便试试新版的聊天界面。',
          DateTime.now(),
        );
        await storage.updateSessionLastMessage(
          'design-user',
          '你好，这里是单聊消息。',
          DateTime.now(),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('capture-ui'),
            child: appShell(storage, bot, plugins),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(MobileWorkspace), findsOneWidget);
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          0,
        );
        expect(find.byTooltip('新建会话'), findsOneWidget);
        await captureUi(
          tester,
          'mobile-${platform.name}-${size.width.toInt()}-sessions',
        );
        await tester.tap(find.text('机器人开发交流群'));
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byTooltip('更多消息功能'), findsOneWidget);
        expect(find.byTooltip('消息设置'), findsNothing);
        await captureUi(
          tester,
          'mobile-${platform.name}-${size.width.toInt()}-chat',
        );
        await revealComposerTools(tester);
        await tester.tap(find.byTooltip('自定义 Markdown'));
        await tester.pumpAndSettle();
        expect(find.byType(MarkdownWorkbench), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('markdown-editor')),
          '# 你好\n\n这是 Markdown 预览。',
        );
        await tester.pumpAndSettle();
        await captureUi(
          tester,
          'mobile-${platform.name}-${size.width.toInt()}-markdown',
        );
        await tester.tap(find.byTooltip('自定义 Markdown'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('收起消息功能'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(
          bottom: size.height > 500 ? 280 : 100,
        );
        await tester.pumpAndSettle();
        expect(find.byType(ChatInput), findsOneWidget);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('返回会话列表'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('插件'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('插件文件管理'), findsOneWidget);
        expect(find.text('插件中心'), findsNothing);
        await captureUi(
          tester,
          'mobile-${platform.name}-${size.width.toInt()}-plugins',
        );
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        await captureUi(
          tester,
          'mobile-${platform.name}-${size.width.toInt()}-settings',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
  testWidgets('小屏深色模式及大字体：会话、聊天和插件仍可操作', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final storage = DarkMemoryStorage();
    final bot = BotClient(storage, apiService: RecordingApi());
    final plugins = PluginManager(storage);
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    await tester.runAsync(plugins.init);
    await bot.addSession('large-font-group', name: '大字体测试群聊', isGroup: true);
    await tester.pumpWidget(appShell(storage, bot, plugins));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(MobileWorkspace))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('大字体测试群聊'));
    await tester.pumpAndSettle();
    await revealComposerTools(tester);
    await tester.tap(find.byTooltip('自定义 Markdown'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('返回会话列表'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('插件'),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
