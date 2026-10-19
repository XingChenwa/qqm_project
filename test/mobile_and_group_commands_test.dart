import 'support/ui_actions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/app.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/settings_screen.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'package:qq_bot_manager/utils/platforms.dart';
import 'package:qq_bot_manager/utils/weather_commands.dart';

import 'support/fakes.dart';

Widget appShell(
  MemoryStorage storage,
  BotClient bot,
  PluginManager plugins, {
  Widget child = const QQBotManagerApp(),
}) => MultiProvider(
  providers: [
    Provider<StorageService>.value(value: storage),
    ChangeNotifierProvider<BotClient>.value(value: bot),
    ChangeNotifierProvider<PluginManager>.value(value: plugins),
  ],
  child: child,
);

Map<String, dynamic> fullEvent(
  String id,
  String text, {
  String type = 'GROUP_MESSAGE_CREATE',
}) => {
  'id': id,
  'sessionId': 'group-1',
  'senderId': 'member-1',
  'senderName': '用户',
  'content': text,
  'rawContent': text,
  'isGroup': true,
  'timestamp': DateTime.now(),
  'eventType': type,
};

void main() {
  test('天气/IP 白名单与插件共用，支持中文和斜杠；日常聊天或其他插件命令不命中', () {
    for (final text in [
      '天气 北京',
      '查询天气',
      '/天气 上海',
      '/IP 114.114.114.114',
      '查ip地址 114.114.114.114',
      '天气：深圳',
    ]) {
      expect(WeatherQuery.parse(text), isNotNull);
    }
    for (final text in [
      '你好',
      '今天天气真好',
      '/help',
      '/dice 2d6',
      '这个 IP 地址是什么',
      '天气 北京\n普通正文',
    ]) {
      expect(WeatherQuery.parse(text), isNull);
    }
  });

  test('iOS/Android 不初始化桌面窗口平台，桌面平台保留窗口管理', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(isMobilePlatform, isTrue);
      expect(isDesktopPlatform, isFalse);
    }
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(isMobilePlatform, isFalse);
      expect(isDesktopPlatform, isTrue);
    }
  });

  testWidgets('无 @ 的群天气/IP 指令实际走发送路径，普通聊天和其他插件不回复；天气停用时不兜底', (tester) async {
    final config = validConfig()
      ..appId = ''
      ..clientSecret = ''
      ..enableAutoReply = true
      ..defaultAutoReply = '不该发出的默认回复';
    final storage = MemoryStorage(config: config);
    final gateway = TestGateway();
    final api = RecordingApi();
    final bot = BotClient(storage, apiService: api, webSocketService: gateway);
    final plugins = PluginManager(storage);
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    await tester.runAsync(() => plugins.init());
    await plugins.enablePlugin('weather_plugin');
    await tester.pumpWidget(appShell(storage, bot, plugins));
    await tester.pumpAndSettle();
    expect(bot.config.autoReplyToAllGroupMessages, isFalse);
    gateway.events.add(fullEvent('ordinary', '你好'));
    gateway.events.add(fullEvent('help', '帮助我看看天气怎么样'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    // “hello”也会命中基础助手，窄范围路由必须确保只处理天气插件。
    gateway.events.add(fullEvent('weather', '天气 hello'));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));
    expect(api.calls.single['content'], contains('高德 Web 服务 Key'));
    expect(api.calls.single['content'], isNot(contains('默认回复')));
    expect(api.calls.single['msgId'], 'weather');
    gateway.events.add(
      fullEvent('weather', '天气 hello', type: 'GROUP_AT_MESSAGE_CREATE'),
    );
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));
    gateway.events.add(fullEvent('ip', '/ip 114.114.114.114'));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(2));
    expect(api.calls.last['msgId'], 'ip');
    await plugins.disablePlugin('weather_plugin');
    gateway.events.add(fullEvent('disabled', '天气 北京'));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(2));
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('手机 ${width.toInt()} 像素会话导航、键盘与消息设置不溢出', (tester) async {
      tester.view.physicalSize = Size(width, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      debugDefaultTargetPlatformOverride = width == 390
          ? TargetPlatform.iOS
          : TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final storage = MemoryStorage();
      final bot = BotClient(storage, apiService: RecordingApi());
      final plugins = PluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await tester.runAsync(() => plugins.init());
      await bot.addSession('group-1', name: '手机测试群聊', isGroup: true);
      await storage.saveMessage(
        MessageModel(
          id: 'mobile-msg',
          sessionId: 'group-1',
          senderId: 'user',
          senderName: '用户',
          content: '这是一条手机聊天测试消息',
          messageType: 0,
          timestamp: DateTime.now(),
        ),
      );
      await tester.pumpWidget(appShell(storage, bot, plugins));
      await tester.pumpAndSettle();
      expect(find.byType(ChatInput), findsNothing);
      await tester.tap(find.text('手机测试群聊'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatInput), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(find.byTooltip('发送'), findsOneWidget);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await revealComposerTools(tester);
      await tester.tap(find.byTooltip('消息设置'));
      await tester.pumpAndSettle();
      expect(find.text('应用设置'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭消息设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回会话列表'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatInput), findsNothing);
      expect(find.byType(Drawer), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('插件'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('配置高德天气与 IP 查询'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('手机 ${width.toInt()} 像素设置页各标签不溢出', (tester) async {
      tester.view.physicalSize = Size(width, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final bot = BotClient(storage, apiService: RecordingApi());
      final plugins = PluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await tester.pumpWidget(
        appShell(
          storage,
          bot,
          plugins,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('自动回复'), findsNothing);
      expect(find.text('关键词回复'), findsNothing);
      for (final label in ['常规', '连接', '数据', '数据清理', '关于']) {
        final tab = find.ancestor(
          of: find.text(label),
          matching: find.byType(ChoiceChip),
        );
        await tester.ensureVisible(tab);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
