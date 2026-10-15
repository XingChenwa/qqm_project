import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';
import 'package:qq_bot_manager/ui/themes/app_theme.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'package:qq_bot_manager/ui/widgets/plugin_import_dialog.dart';
import 'package:qq_bot_manager/ui/widgets/plugin_panel.dart';

import 'support/fakes.dart';

const captureUi = bool.fromEnvironment('QQM_CAPTURE_UI');

Widget shell(
  MemoryStorage storage,
  PluginManager manager,
  BotClient bot, {
  Widget? child,
}) => MultiProvider(
  providers: [
    Provider<StorageService>.value(value: storage),
    ChangeNotifierProvider<PluginManager>.value(value: manager),
    ChangeNotifierProvider<BotClient>.value(value: bot),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.lightTheme,
    home:
        child ??
        const MainScreen(toggleTheme: noop, themeMode: ThemeMode.light),
  ),
);
void noop() {}

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!captureUi) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/ui-previews');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in [
      'plugins/index.json',
      'docs/plugin-development.md',
      'plugins/examples/hello_json/plugin.json',
      'plugins/examples/hello_yaml/plugin.yaml',
      'plugins/examples/http_echo/plugin.json',
    ]) {
      await rootBundle.loadString(path);
    }
    if (captureUi && Platform.isWindows) {
      final loader = FontLoader('Microsoft YaHei');
      for (final path in [
        r'C:\Windows\Fonts\msyh.ttc',
        r'C:\Windows\Fonts\msyhbd.ttc',
      ]) {
        if (File(path).existsSync()) {
          loader.addFont(
            Future.value(ByteData.sublistView(await File(path).readAsBytes())),
          );
        }
      }
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final codeBytes = ByteData.sublistView(
        await File(r'C:\Windows\Fonts\consola.ttf').readAsBytes(),
      );
      for (final family in ['Consolas', 'monospace']) {
        await (FontLoader(family)..addFont(Future.value(codeBytes))).load();
      }
    }
  });

  testWidgets('导入必须检查并授权，默认停用；配置、启用、卸载均可操作', (tester) async {
    final storage = MemoryStorage();
    final manager = PluginManager(storage);
    final bot = BotClient(storage);
    addTearDown(manager.dispose);
    addTearDown(bot.dispose);
    await tester.runAsync(manager.init);
    await tester.pumpWidget(
      shell(storage, manager, bot, child: const Scaffold(body: PluginPanel())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    final source = File(
      'plugins/examples/hello_json/plugin.json',
    ).readAsStringSync();
    await tester.enterText(
      find.byKey(const ValueKey('plugin-manifest-source')),
      source,
    );
    await tester.tap(find.text('检查清单'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认导入'))
          .onPressed,
      isNull,
    );
    expect(manager.plugins, hasLength(4));
    await tester.tap(find.byKey(const ValueKey('plugin-import-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(manager.plugins, hasLength(5));
    expect(manager.plugins.last.info.isEnabled, false);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('plugin-card-custom_hello'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: card,
        matching: find.widgetWithText(OutlinedButton, '配置'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '欢迎你');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(storage.storedPlugins['custom_hello']!.config['salutation'], '欢迎你');
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(card);
    await tester.tap(find.descendant(of: card, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(manager.plugins.last.info.isEnabled, true);
    await tester.tap(
      find.descendant(of: card, matching: find.byTooltip('卸载插件')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '卸载'));
    await tester.pumpAndSettle();
    expect(manager.plugins, hasLength(4));
    expect(storage.storedPlugins.containsKey('custom_hello'), false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('应用内开发文档和示例可读，加载示例不会自动安装', (tester) async {
    final storage = MemoryStorage();
    final manager = PluginManager(storage);
    final bot = BotClient(storage);
    addTearDown(manager.dispose);
    addTearDown(bot.dispose);
    await tester.runAsync(manager.init);
    await tester.runAsync(() async {
      await rootBundle.loadString('docs/plugin-development.md');
      await rootBundle.loadString('plugins/examples/hello_json/plugin.json');
    });
    await tester.pumpWidget(
      shell(storage, manager, bot, child: const Scaffold(body: PluginPanel())),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('开发者文档与示例'));
      for (final path in [
        'docs/plugin-development.md',
        'plugins/examples/hello_json/plugin.json',
        'plugins/examples/hello_yaml/plugin.yaml',
        'plugins/examples/http_echo/plugin.json',
      ]) {
        await rootBundle.loadString(path);
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('开发者中心'), findsOneWidget);
    await tester.tap(find.text('JSON 示例'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('使用这个示例')));
    await tester.pumpAndSettle();
    expect(find.byType(PluginImportDialog), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('plugin-manifest-source')),
          )
          .controller!
          .text,
      contains('custom_hello'),
    );
    expect(manager.plugins, hasLength(4));
    await tester.tap(find.byTooltip('关闭插件导入'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0, 960.0, 1280.0]) {
    testWidgets('新版 UI ${width.toInt()} 像素聊天、总览、插件及导入无溢出', (tester) async {
      tester.view.physicalSize = Size(width, width < 700 ? 840 : 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      debugDefaultTargetPlatformOverride = width < 700
          ? TargetPlatform.android
          : TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final storage = MemoryStorage();
      final manager = PluginManager(storage);
      final bot = BotClient(storage);
      addTearDown(manager.dispose);
      addTearDown(bot.dispose);
      await tester.runAsync(manager.init);
      await bot.addSession('fixture-group', name: '机器人开发交流群', isGroup: true);
      await bot.addSession('fixture-private', name: '小林', isGroup: false);
      final now = DateTime.now();
      for (final (index, text, fromBot) in [
        (0, '新版本的插件可以直接导入 JSON 吗？', false),
        (1, '可以，打开插件中心导入清单，检查配置后再启用。', true),
        (2, '太好了，我想写一个自己的命令。', false),
        (3, '```json\n{"runtime": "rules", "schema_version": 1}\n```', true),
      ]) {
        await storage.saveMessage(
          MessageModel(
            id: 'fixture-$index',
            sessionId: 'fixture-group',
            senderId: fromBot ? 'fixture-bot' : 'fixture-user',
            senderName: fromBot ? '机器人助手' : '小明',
            content: text,
            messageType: fromBot ? 2 : 0,
            isFromBot: fromBot,
            timestamp: now.subtract(Duration(minutes: 5 - index)),
          ),
        );
      }
      await manager.installPlugin(
        File('plugins/examples/hello_json/plugin.json').readAsStringSync(),
      );
      final http =
          jsonDecode(
                File(
                  'plugins/examples/http_echo/plugin.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      (http['http'] as Map)['url'] = 'https://plugins.example/qqbot';
      await manager.installPlugin(jsonEncode(http));
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: key, child: shell(storage, manager, bot)),
      );
      await tester.pumpAndSettle();
      if (width >= 700) {
        expect(find.byType(ChatInput), findsOneWidget);
        await capture(tester, key, 'chat-${width.toInt()}');
      }
      await tester.tap(
        width < 700
            ? find.widgetWithText(NavigationDestination, '总览')
            : find.text('总览'),
      );
      await tester.pumpAndSettle();
      expect(find.text('你的机器人工作空间'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (width >= 700) await capture(tester, key, 'overview-${width.toInt()}');
      await tester.tap(
        width < 700
            ? find.widgetWithText(NavigationDestination, '插件')
            : find.text('插件'),
      );
      await tester.pumpAndSettle();
      expect(find.text('插件中心'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'plugins-${width.toInt()}');
      await tester.tap(find.widgetWithText(FilledButton, '导入'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      expect(find.text('检查清单'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭插件导入'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('已导入 JSON 插件经真实宿主回复路径发送 Markdown，普通全量群聊仍不触发', (tester) async {
    final config = validConfig()
      ..appId = ''
      ..clientSecret = '';
    final storage = MemoryStorage(config: config);
    final manager = PluginManager(storage);
    final api = RecordingApi();
    final gateway = TestGateway();
    final bot = BotClient(storage, apiService: api, webSocketService: gateway);
    addTearDown(manager.dispose);
    addTearDown(bot.dispose);
    await tester.runAsync(manager.init);
    await manager.installPlugin(
      File('plugins/examples/hello_json/plugin.json').readAsStringSync(),
    );
    await manager.enablePlugin('custom_hello');
    await tester.pumpWidget(shell(storage, manager, bot));
    await tester.pumpAndSettle();
    Map<String, dynamic> event(String type) => {
      'id': 'external-source',
      'sessionId': 'group-1',
      'senderId': 'member-1',
      'senderName': '用户',
      'content': '开发者示例',
      'rawContent': '开发者示例',
      'isGroup': true,
      'timestamp': DateTime.now(),
      'eventType': type,
    };
    gateway.events.add(event('GROUP_MESSAGE_CREATE'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    gateway.events.add(event('GROUP_AT_MESSAGE_CREATE'));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));
    expect(api.calls.single['type'], 2);
    expect(api.calls.single['msgId'], 'external-source');
    expect(api.calls.single['content'], contains('**Markdown**'));
    gateway.events.add(event('GROUP_AT_MESSAGE_CREATE'));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));
  });
}
