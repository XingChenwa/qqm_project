import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/app.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/settings_screen.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'package:qq_bot_manager/utils/helpers.dart';

import 'support/fakes.dart';

class CodeReplyPlugins extends PluginManager {
  CodeReplyPlugins(super.storage);

  @override
  Future<List<PluginResponse>> processMessage(
    PluginMessage message, {
    String? onlyPluginId,
  }) async => message.content == '未开启全量自动回复时只展示'
      ? []
      : [
          const PluginResponse(
            pluginId: 'test',
            pluginName: '代码测试',
            content: '```python\n# 中文注释\n    print("你好")\n```',
          ),
        ];
}

void main() {
  test('翻译命令保留换行和缩进，群聊机器人提及可以被移除', () {
    const body = '```python\n# comment\nif True:\n    print("hello")\n```';
    final parsed = parseSlashCommand(
      stripLeadingBotMention('<@!bot> /translate $body'),
    );
    expect(parsed?.command, 'translate');
    expect(parsed?.args.single, body);
  });

  testWidgets('代码块自动使用 Markdown，回车发送且不改动原文', (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInput(
            onSendText: (_) async {
              fail('代码块不应以普通文本发送');
            },
            onSendMarkdown:
                (markdown, {useTemplate, templateId, templateParams}) async {
                  sent = markdown;
                  return true;
                },
            onSendImage: (_) async => true,
          ),
        ),
      ),
    );
    const code = '```python\n# 中文\nif True:\n    print("你好")\n```';
    await tester.enterText(find.byType(TextField), code);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, code);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('Markdown 模式的斜杠正文不会被截走执行插件，失败时保留输入并显示原因', (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInput(
            onSendText: (_) async => true,
            onSendMarkdown:
                (markdown, {useTemplate, templateId, templateParams}) async {
                  sent = markdown;
                  return false;
                },
            onSendImage: (_) async => true,
            onSlashCommand: (_, _) async {
              fail('Markdown 原文不应进入命令处理');
            },
            sendError: () => '平台返回：测试错误',
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('自定义 Markdown'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '/path/to/file\n```dart\n  main() {}\n```',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(sent, '/path/to/file\n```dart\n  main() {}\n```');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      sent,
    );
    expect(find.text('平台返回：测试错误'), findsOneWidget);
  });

  for (final width in [1280.0, 960.0]) {
    testWidgets('中文设置页面在 ${width.toInt()} 像素窗口正常布局', (tester) async {
      tester.view.physicalSize = Size(width, width == 960 ? 600 : 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final bot = BotClient(storage, apiService: RecordingApi());
      final plugins = PluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storage),
            ChangeNotifierProvider<BotClient>.value(value: bot),
            ChangeNotifierProvider<PluginManager>.value(value: plugins),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pump();
      expect(find.text('机器人凭据'), findsOneWidget);
      expect(find.text('扫码连接（推荐）'), findsOneWidget);
      expect(find.text('测试凭据'), findsNothing);
      await tester.tap(find.text('手动配置'));
      await tester.pumpAndSettle();
      expect(find.text('测试凭据'), findsOneWidget);
      expect(find.text('验证成功'), findsNothing);
      // Flutter 会在测试结束时自动报告未处理的布局异常。
    });
  }

  testWidgets('最小 960x600 窗口能显示中文聊天输入区', (tester) async {
    tester.view.physicalSize = const Size(960, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStorage();
    final bot = BotClient(storage, apiService: RecordingApi());
    final plugins = PluginManager(storage);
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    await bot.addSession('group-1', isGroup: true);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<BotClient>.value(value: bot),
          ChangeNotifierProvider<PluginManager>.value(value: plugins),
        ],
        child: const QQBotManagerApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatInput), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);
  });

  for (final eventType in ['', 'GROUP_MESSAGE_CREATE']) {
    testWidgets(
      '收到插件代码回复后真正发送到 QQ，并只保留一条成功气泡：${eventType.isEmpty ? '普通事件' : '全量事件'}',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final config = validConfig()
          ..appId = ''
          ..clientSecret = '';
        final storage = MemoryStorage(config: config);
        final api = RecordingApi();
        final gateway = TestGateway();
        final bot = BotClient(
          storage,
          apiService: api,
          webSocketService: gateway,
        );
        final plugins = CodeReplyPlugins(storage);
        addTearDown(bot.dispose);
        addTearDown(plugins.dispose);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              Provider<StorageService>.value(value: storage),
              ChangeNotifierProvider<BotClient>.value(value: bot),
              ChangeNotifierProvider<PluginManager>.value(value: plugins),
            ],
            child: const QQBotManagerApp(),
          ),
        );
        await tester.pump();
        if (eventType.isNotEmpty) {
          gateway.events.add({
            'id': 'display-only',
            'sessionId': 'group-1',
            'senderId': 'member-1',
            'senderName': '测试用户',
            'content': '未开启全量自动回复时只展示',
            'isGroup': true,
            'timestamp': DateTime.now(),
            'eventType': eventType,
          });
          await tester.pumpAndSettle();
          expect(api.calls, isEmpty);
          expect(bot.messages.single.content, '未开启全量自动回复时只展示');
          bot.config.autoReplyToAllGroupMessages = true;
        }
        gateway.events.add({
          'id': 'inbound',
          'sessionId': 'group-1',
          'senderId': 'member-1',
          'senderName': '测试用户',
          'content': '翻译代码',
          'isGroup': true,
          'timestamp': DateTime.now(),
          'eventType': eventType,
        });
        await tester.pumpAndSettle();
        expect(api.calls.single['type'], 2);
        expect(api.calls.single['msgId'], 'inbound');
        expect(api.calls.single['content'], contains('\n    print'));
        expect(bot.messages.where((m) => m.isFromBot), hasLength(1));
        expect(bot.messages.last.id, 'sent-1');
        expect(find.text('聊天工作台'), findsOneWidget);
        expect(
          Localizations.localeOf(
            tester.element(find.byType(ChatInput)),
          ).languageCode,
          'zh',
        );
        // Flutter 会在测试结束时自动报告未处理的布局异常。
      },
    );
  }
}
