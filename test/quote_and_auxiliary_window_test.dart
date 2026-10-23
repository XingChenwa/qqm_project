import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/models/received_message.dart';
import 'package:qq_bot_manager/services/auxiliary_window_controller.dart';
import 'package:qq_bot_manager/services/auxiliary_windows.dart';
import 'package:qq_bot_manager/ui/screens/archive_window_screen.dart';
import 'package:qq_bot_manager/ui/screens/forwarded_record_screen.dart';
import 'package:qq_bot_manager/ui/themes/app_theme.dart';
import 'package:qq_bot_manager/ui/widgets/desktop_window_frame.dart';
import 'package:qq_bot_manager/ui/widgets/received_message_view.dart';
import 'package:qq_bot_manager/utils/forwarded_text.dart';

const quotedExport = '''=== 消息 1 ===
[消息内容] <qqbot-at-user id="member" /> 你电脑上没有吗？
[消息类型] 引用消息
''';

class QuoteWindows extends AuxiliaryWindows {
  var opens = 0;
  QuoteWindows() : super(supported: true, executable: 'fixture.exe');
  @override
  Future<void> open(String kind, Map<String, dynamic> data) async => opens++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('单条编号引用导出保留引用类型，不把消息类型字段拼进正文', () {
    final parsed = parseForwardedRecordText(quotedExport)!;
    expect(parsed['message_type'], 103);
    expect(parsed['content'], '<qqbot-at-user id="member" /> 你电脑上没有吗？');
    expect(parsed.containsKey('record_title'), isFalse);
    for (final raw in [
      {'message_type': 103, 'content': quotedExport},
      {
        'message_type': 103,
        'content': ' ',
        'msg_elements': [
          {'content': quotedExport},
        ],
      },
    ]) {
      final original = jsonEncode(raw);
      final body = ReceivedMessageBody.fromMap(raw);
      expect(body.type, 103);
      expect(body.isRecord, isFalse);
      expect(body.preview, isNot(contains('[消息类型]')));
      expect(jsonEncode(raw), original);
      expect(
        ReceivedMessageBody.fromMap(body.toDisplayMap()).isRecord,
        isFalse,
      );
    }
  });

  test('单条无标题文本不是合并记录，明确的 102 或聊天记录标题仍支持单条转发', () {
    const one = '=== 消息 1 ===\n[消息内容] 单条正文\n[发送者] 小明';
    expect(ReceivedMessageBody.fromMap({'content': one}).isRecord, isFalse);
    for (final raw in [
      {'message_type': 102, 'content': one},
      {'content': '[小明的聊天记录]\n$one'},
      {'content': '[群聊的聊天记录]\n$quotedExport'},
    ]) {
      final body = ReceivedMessageBody.fromMap(raw);
      expect(body.isRecord, isTrue);
      expect(body.elements, hasLength(1));
    }
  });

  test('真实多条记录仍可独立打开，回复真正的聊天记录也不丢失回复正文', () {
    const records = '=== 消息 1 ===\n[消息内容] 第一条\n=== 消息 2 ===\n[消息内容] 第二条';
    final record = ReceivedMessageBody.fromMap({'content': records});
    expect(record.isRecord, isTrue);
    expect(record.elements, hasLength(2));
    final reply = ReceivedMessageBody.fromMap({
      'message_type': 103,
      'content': '我在回复这份记录',
      'msg_elements': [record.toDisplayMap()],
    });
    expect(reply.isRecord, isFalse);
    expect(reply.displayText, '我在回复这份记录');
    expect(reply.elements.single.isRecord, isTrue);
  });

  test('引用导出识别引用作者与原文，不将元数据混入当前回复', () {
    final body = ReceivedMessageBody.fromMap({
      'message_type': 103,
      'content': '''=== 消息 1 ===
[消息内容] 这是我的回复
[消息类型] 引用消息
[引用发送者] 小明
[引用内容] 被引用的原文
''',
    });
    expect(body.type, 103);
    expect(body.isRecord, isFalse);
    expect(body.text, '这是我的回复');
    expect(body.elements.single.text, '被引用的原文');
    expect(body.elements.single.authorName, '小明');
  });

  for (final width in [360.0, 820.0]) {
    testWidgets('引用消息只在原气泡展开，不创建聊天记录窗口 $width', (tester) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final windows = QuoteWindows();
      final body = ReceivedMessageBody.fromMap({
        'message_type': 103,
        'content': '这是回复',
        'mentions': [
          {'id': 'member', 'username': '大肥鱼'},
        ],
        'msg_elements': [
          {'content': quotedExport},
        ],
      });
      await tester.pumpWidget(
        Provider<AuxiliaryWindows>.value(
          value: windows,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: ReceivedMessageView(body: body, storageKey: 'quote'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('forwarded-record-card')), findsNothing);
      expect(find.byKey(const ValueKey('quoted-message')), findsOneWidget);
      expect(find.text('这是回复'), findsOneWidget);
      expect(find.textContaining('@大肥鱼', findRichText: true), findsOneWidget);
      expect(find.textContaining('[消息类型]'), findsNothing);
      await tester.tap(find.text('引用消息 · 1 个元素'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用消息 · 1 个元素'));
      await tester.pumpAndSettle();
      expect(find.textContaining('@大肥鱼', findRichText: true), findsOneWidget);
      expect(windows.opens, 0);
      expect(find.byType(ForwardedRecordScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  group('桌面独立窗口自定义标题栏', () {
    const channel = MethodChannel('window_manager');
    const screen = MethodChannel('dev.leanflutter.plugins/screen_retriever');
    const tray = MethodChannel('tray_manager');
    late List<MethodCall> calls;
    late int trayCalls;
    var maximized = false, failFrameless = false;
    const display = {
      'id': 'test-display',
      'size': {'width': 1920.0, 'height': 1080.0},
      'visibleSize': {'width': 1920.0, 'height': 1040.0},
      'visiblePosition': {'dx': 0.0, 'dy': 0.0},
      'scaleFactor': 1.0,
    };
    setUp(() {
      calls = [];
      trayCalls = 0;
      maximized = false;
      failFrameless = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'isMaximized':
            return maximized;
          case 'isMinimized' || 'isFullScreen':
            return false;
          case 'maximize':
            maximized = true;
          case 'unmaximize':
            maximized = false;
          case 'getBounds':
            return {'x': 0.0, 'y': 0.0, 'width': 820.0, 'height': 850.0};
          case 'setAsFrameless':
            if (failFrameless) throw PlatformException(code: 'test');
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        screen,
        (call) async => switch (call.method) {
          'getPrimaryDisplay' => display,
          'getAllDisplays' => {
            'displays': [display],
          },
          'getCursorScreenPoint' => {'dx': 500.0, 'dy': 300.0},
          _ => null,
        },
      );
      messenger.setMockMethodCallHandler(tray, (_) async {
        trayCalls++;
        return null;
      });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final target in [channel, screen, tray]) {
        messenger.setMockMethodCallHandler(target, null);
      }
    });

    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
      test('初始化隐藏系统标题栏、显示任务栏且不初始化托盘 $platform', () async {
        debugDefaultTargetPlatformOverride = platform;
        final controller = AuxiliaryWindowController(supported: true);
        addTearDown(controller.dispose);
        await controller.initialize(title: '聊天记录', size: const Size(820, 850));
        expect(controller.ready, isTrue);
        expect(controller.error, isEmpty);
        expect(calls.map((c) => c.method), contains('setAsFrameless'));
        final style = calls.firstWhere((c) => c.method == 'setTitleBarStyle');
        expect(style.arguments['titleBarStyle'], 'hidden');
        expect(style.arguments['windowButtonVisibility'], isFalse);
        expect(
          calls
              .firstWhere((c) => c.method == 'setSkipTaskbar')
              .arguments['isSkipTaskbar'],
          isFalse,
        );
        expect(trayCalls, 0);
        await controller.requestClose();
        expect(calls.where((c) => c.method == 'close'), hasLength(1));
        expect(
          calls.any((c) => c.method == 'hide' || c.method == 'destroy'),
          isFalse,
        );
        await controller.requestClose();
        expect(calls.where((c) => c.method == 'close'), hasLength(1));
      });
    }

    test('原生初始化失败仍保留系统按钮，不能成为无法关闭的窗口', () async {
      failFrameless = true;
      final controller = AuxiliaryWindowController(supported: true);
      addTearDown(controller.dispose);
      await controller.initialize(title: '聊天记录', size: const Size(820, 850));
      expect(controller.ready, isFalse);
      expect(controller.error, contains('已保留系统窗口操作'));
      expect(
        calls
            .lastWhere((c) => c.method == 'setTitleBarStyle')
            .arguments['titleBarStyle'],
        'normal',
      );
      expect(calls.map((c) => c.method), contains('show'));
      expect(trayCalls, 0);
    });

    for (final width in [420.0, 820.0]) {
      testWidgets('最小宽度下自定义按钮、拖动、双击、边缘缩放不挤出内容 $width', (tester) async {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = AuxiliaryWindowController(supported: true)
          ..ready = true;
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            builder: (context, child) => DesktopWindowFrame(
              controller: controller,
              title: '这是一个比较长的群聊名称 · 聊天记录',
              showVersion: false,
              closeTooltip: '关闭此窗口',
              child: child!,
            ),
            home: ArchiveWindowScreen(
              title: '群聊',
              messages: const [],
              onClose: controller.requestClose,
              showAppBar: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsNothing);
        expect(find.byTooltip('关闭此窗口'), findsOneWidget);
        expect(find.byTooltip('关闭聊天记录窗口'), findsNothing);
        expect(find.text('没有符合条件的聊天记录'), findsOneWidget);
        await tester.tap(find.byTooltip('最大化'));
        await tester.pumpAndSettle();
        expect(maximized, isTrue);
        expect(find.byTooltip('还原窗口'), findsOneWidget);
        final region = find.byKey(const ValueKey('window-drag-region'));
        await tester.tap(region);
        await tester.pump(const Duration(milliseconds: 70));
        await tester.tap(region);
        await tester.pumpAndSettle();
        expect(maximized, isFalse);
        await tester.drag(region, const Offset(50, 0));
        await tester.pumpAndSettle();
        expect(calls.map((c) => c.method), contains('startDragging'));
        await tester.tap(find.byTooltip('最小化'));
        await tester.pumpAndSettle();
        expect(calls.map((c) => c.method), contains('minimize'));
        await tester.tap(find.byTooltip('关闭此窗口'));
        await tester.pumpAndSettle();
        expect(calls.map((c) => c.method), contains('close'));
        expect(trayCalls, 0);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });
}
