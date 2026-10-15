import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/browser_screen.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';
import 'package:qq_bot_manager/ui/screens/settings_screen.dart';
import 'package:qq_bot_manager/ui/themes/app_theme.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'package:qq_bot_manager/ui/widgets/linkified_text.dart';
import 'package:qq_bot_manager/ui/widgets/log_panel.dart';

import 'support/fakes.dart';

const _capture = bool.fromEnvironment('QQM_CAPTURE_UI');

Future<void> _snapshot(WidgetTester tester, GlobalKey key, String name) async {
  if (!_capture) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('build/ui-previews').create(recursive: true);
    await File(
      'build/ui-previews/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget _host(
  MemoryStorage storage,
  BotClient bot,
  PluginManager plugins,
  Widget child,
) => MultiProvider(
  providers: [
    Provider<StorageService>.value(value: storage),
    ChangeNotifierProvider<BotClient>.value(value: bot),
    ChangeNotifierProvider<PluginManager>.value(value: plugins),
  ],
  child: MaterialApp(theme: AppTheme.lightTheme, home: child),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (_capture && Platform.isWindows) {
      final loader = FontLoader('Microsoft YaHei');
      for (final file in [
        r'C:\Windows\Fonts\msyh.ttc',
        r'C:\Windows\Fonts\msyhbd.ttc',
      ]) {
        loader.addFont(
          Future.value(ByteData.sublistView(await File(file).readAsBytes())),
        );
      }
      await loader.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await (FontLoader('Consolas')..addFont(
            Future.value(
              ByteData.sublistView(
                await File(r'C:\Windows\Fonts\consola.ttf').readAsBytes(),
              ),
            ),
          ))
          .load();
    }
  });

  test('内置浏览器只接收无凭据的网页地址，拒绝外部协议和本地文件', () {
    expect(browserUri('https://example.com/文档?a=1')?.host, 'example.com');
    expect(browserUri('http://127.0.0.1:8080')?.port, 8080);
    for (final url in [
      'file:///C:/secret.txt',
      'javascript:alert(1)',
      'intent://open',
      'mqqapi://open',
      'https://user:secret@example.com',
      'https:',
      'not a url',
    ]) {
      expect(browserUri(url), isNull);
    }
  });

  testWidgets('普通消息链接进入应用内页面，运行时缺失也不会启动外部浏览器', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const LinkifiedText('官网 https://example.com/page。'),
        ),
      ),
    );
    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    final span = selectable.textSpan!.children!
        .whereType<TextSpan>()
        .firstWhere((s) => s.recognizer != null);
    expect(span.text, 'https://example.com/page');
    (span.recognizer as dynamic).onTap();
    await tester.pumpAndSettle();
    expect(find.byType(BrowserScreen), findsOneWidget);
    expect(find.byTooltip('复制链接'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭内置浏览器'));
    await tester.pumpAndSettle();
    expect(find.byType(BrowserScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('日志全复制和 TXT/LOG 导出保留中文、换行和时间顺序', (tester) async {
    const logs = ['[01:00:00] 连接成功', '[01:00:01] 中文错误\n详细原因'];
    final clipboard = <String>[];
    final saved = <Map>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add(call.arguments['text'] as String);
      }
      return null;
    });
    // The package's unregistered test backend uses its method channel.
    const pickerChannel = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
    );
    messenger.setMockMethodCallHandler(pickerChannel, (call) async {
      if (call.method == 'save') {
        saved.add(call.arguments as Map);
        return 'saved-file';
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(pickerChannel, null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogPanel(logs: logs)),
      ),
    );
    await tester.tap(find.byTooltip('复制全部日志'));
    await tester.pumpAndSettle();
    expect(clipboard.single, logs.join('\r\n'));
    for (final extension in ['TXT', 'LOG']) {
      await tester.tap(find.byTooltip('导出全部日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出为 $extension'));
      await tester.pumpAndSettle();
    }
    expect(saved.length, 2);
    for (final (index, extension) in ['txt', 'log'].indexed) {
      final data = saved[index];
      expect(data['fileName'], endsWith('.$extension'));
      final bytes = (data['bytes'] as List).cast<int>();
      expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
      expect(utf8.decode(bytes.skip(3).toList()), logs.join('\r\n'));
    }
  });

  for (final width in [320.0, 390.0, 960.0, 1280.0]) {
    testWidgets('Markdown 独立草稿、预览和发送在 ${width.toInt()} 像素可用', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? sent;
      var failSend = true;
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: AppTheme.lightBg,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ChatInput(
                    onSendText: (_) async => true,
                    onSendMarkdown:
                        (
                          text, {
                          useTemplate,
                          templateId,
                          templateParams,
                        }) async {
                          sent = text;
                          return !failSend;
                        },
                    onSendImage: (_) async => true,
                    sendError: () => '测试失败，草稿保留',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '普通文本草稿');
      await tester.tap(find.byTooltip('自定义 Markdown'));
      await tester.pumpAndSettle();
      const body =
          '# 中文标题\n\n```dart\n  print("你好");\n```\n\n[官方文档](https://bot.q.qq.com/wiki/)';
      await tester.enterText(
        find.byKey(const ValueKey('markdown-editor')),
        body,
      );
      await tester.pumpAndSettle();
      final markdown = tester.widget<Markdown>(
        find.byKey(
          const ValueKey('markdown-live-preview'),
          skipOffstage: false,
        ),
      );
      expect(markdown.data, body);
      expect(sent, isNull);
      if (width < 620) {
        await tester.tap(find.text('预览'));
        await tester.pumpAndSettle();
        expect(find.text('中文标题'), findsOneWidget);
        await tester.tap(find.text('编辑'));
        await tester.pumpAndSettle();
      }
      await _snapshot(tester, key, 'markdown-${width.toInt()}');
      await tester.tap(find.text('发送 Markdown'));
      await tester.pumpAndSettle();
      expect(sent, body);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('markdown-editor')))
            .controller!
            .text,
        body,
      );
      await tester.tap(find.byTooltip('自定义 Markdown'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '普通文本草稿',
      );
      await tester.tap(find.byTooltip('自定义 Markdown'));
      await tester.pumpAndSettle();
      failSend = false;
      await tester.tap(find.text('发送 Markdown'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('markdown-editor')))
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('聊天重新打开总是显示最新消息，切换页面、会话和窗口尺寸仍在底部', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStorage();
    for (final sessionId in ['a', 'b']) {
      storage.storedSessions[sessionId] = ChatSession(
        id: sessionId,
        name: '会话 $sessionId',
        sessionType: 0,
        lastMessageTime: DateTime(2026, 10, 15),
      );
      for (var i = 0; i < 80; i++) {
        storage.storedMessages['$sessionId-$i'] = MessageModel(
          id: '$sessionId-$i',
          sessionId: sessionId,
          senderId: 'user',
          senderName: '用户',
          messageType: 0,
          content: '$sessionId 消息 $i\n多行内容\n第三行',
          timestamp: DateTime(2026, 10, 15, 0, i),
        );
      }
    }
    final bot = BotClient(storage, apiService: RecordingApi());
    final plugins = PluginManager(storage);
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    await tester.pumpWidget(
      _host(
        storage,
        bot,
        plugins,
        const MainScreen(toggleTheme: _noop, themeMode: ThemeMode.light),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('messages-a'));
    expect(list, findsOneWidget);
    final controller = tester.widget<CustomScrollView>(list).controller!;
    expect(controller.offset, 0);
    controller.jumpTo(-600);
    await tester.pumpAndSettle();
    await tester.tap(find.text('日志').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('聊天会话').first);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    await tester.tap(find.text('会话 b').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('messages-b')), findsOneWidget);
    expect(controller.offset, 0);
    tester.view.physicalSize = const Size(960, 600);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('手机 $width 宽聊天内 Markdown 在键盘展开后不溢出且可发送', (tester) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final storage = MemoryStorage();
      storage.storedSessions['mobile'] = ChatSession(
        id: 'mobile',
        name: '测试聊天',
        sessionType: 0,
        lastMessageTime: DateTime(2026, 10, 15),
      );
      final bot = BotClient(storage, apiService: RecordingApi());
      final plugins = PluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        _host(
          storage,
          bot,
          plugins,
          RepaintBoundary(
            key: key,
            child: const MainScreen(
              toggleTheme: _noop,
              themeMode: ThemeMode.light,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试聊天').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('自定义 Markdown'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('markdown-editor')),
        '# 手机编辑\n\n独立预览和发送',
      );
      await tester.pumpAndSettle();
      await _snapshot(tester, key, 'chat-markdown-${width.toInt()}');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('发送 Markdown'));
      await tester.pumpAndSettle();
      expect(find.text('发送 Markdown'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 1280.0]) {
    testWidgets('关于页在 $width 宽只显示指定的作者及学习用途文案', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final bot = BotClient(storage);
      final plugins = PluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await tester.pumpWidget(
        _host(storage, bot, plugins, const SettingsScreen()),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('关于'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
      expect(find.text('QQ机器人管理器'), findsOneWidget);
      expect(find.text('基于QQ官方开放平台的跨平台桌面管理工具。'), findsOneWidget);
      expect(find.text('学习为目的编写的'), findsOneWidget);
      expect(find.text('作者QQ：2377130783'), findsOneWidget);
      expect(find.text('问题建议可以反馈'), findsOneWidget);
      expect(find.textContaining('单聊昵称默认由'), findsNothing);
      expect(find.textContaining('第三方服务说明'), findsNothing);
      expect(find.textContaining('不发送密钥'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('设置页移除空菜单、未实现任务和无效关注会话配置', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStorage();
    final bot = BotClient(storage);
    final plugins = PluginManager(storage);
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    await tester.pumpWidget(
      _host(storage, bot, plugins, const SettingsScreen()),
    );
    await tester.pumpAndSettle();
    for (final text in ['好友', '事件', '插件中心', '关注的会话', '定时任务（暂未实现）']) {
      expect(find.text(text), findsNothing);
    }
    expect(find.text('返回工作台'), findsOneWidget);
    expect(find.text('测试凭据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
