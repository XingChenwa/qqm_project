import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/onebot.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/ui/workspace.dart';
import 'package:qq_bot_manager/agent/ui/chat.dart';
import 'package:qq_bot_manager/agent/message_context.dart';
import 'package:qq_bot_manager/ui/screens/forwarded_record_screen.dart';
import 'package:qq_bot_manager/services/qq_qr_login_service.dart';
import 'package:qq_bot_manager/ui/themes/app_theme.dart';

class UiTransport extends AgentTransport {
  bool online = false;
  final sent = <Json>[];
  @override
  bool get connected => online;
  @override
  String get nickname => '我的 AI 助手';
  @override
  String get status => online ? '已连接' : '未连接';
  @override
  Future<void> start() async {
    online = true;
    onState?.call();
  }

  @override
  Future<void> stop() async {
    online = false;
    onState?.call();
  }

  @override
  Future<dynamic> call(String action, [Json params = const {}]) async {
    sent.add(params);
    return {'message_id': 'out-${sent.length}'};
  }
}

class AgentQrFixture extends QqQrLoginService {
  @override
  Future<void> start() async {
    phase = QrLoginPhase.authorized;
    credentials = const QrBotCredentials('10000001', 'agent-qr-fixture-secret');
    notifyListeners();
  }
}

class UiCountingStore extends AgentStore {
  int historyReads = 0;
  UiCountingStore() : super.memory();
  @override
  Json? get(String key) {
    if (key.startsWith('history:')) historyReads++;
    return super.get(key);
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (const bool.fromEnvironment('QQM_CAPTURE_UI') && Platform.isWindows) {
      final bytes = ByteData.sublistView(
        await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes(),
      );
      for (final name in ['Microsoft YaHei', 'Roboto', 'monospace']) {
        await (FontLoader(name)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  late AgentController agent;
  late UiTransport transport;
  late AgentSession session;
  Future<void> prepare({AgentStore? store}) async {
    transport = UiTransport();
    agent = AgentController(
      store: store ?? AgentStore.memory(),
      transportFactory: (c) => c.id == 'demo' ? transport : UiTransport(),
    );
    await agent.initialize();
    await agent.saveConnection(
      AgentConnection(id: 'demo', name: '开发群助手', selfId: '10001'),
    );
    await agent.connect('demo');
    session = await agent.openSession(
      'demo',
      'group',
      '20002',
      name: 'Agent 体验群',
    );
    for (var i = 0; i < 35; i++) {
      await agent.store.append(
        AgentMessage(
          id: 'ob:$i',
          sessionKey: session.key,
          senderId: '30003',
          senderName: '演示成员',
          segments: [textSegment('这是一条独立 Agent 会话的演示消息 $i')],
          time: DateTime(2026, 10, 24, 14, i),
        ),
      );
    }
  }

  void agentTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        // Drain the store in the same fake-async zone that created its queue.
        await agent.shutdown();
        agent.dispose();
      }
    });
  }

  Future<void> host(
    WidgetTester tester,
    double width, {
    Widget? child,
    bool initialize = true,
  }) async {
    if (initialize) await prepare();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 850);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AgentController>.value(
        value: agent,
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: child ?? const AgentWorkspace(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [360.0, 1280.0]) {
    agentTest('Agent $width 新AI能力表单可配置且思考折叠区不溢出', (tester) async {
      await prepare();
      await agent.saveProvider(
        AgentProvider(
          id: 'vision',
          name: '测试视觉模型',
          baseUrl: 'https://vision.example/v1',
          model: 'vision-model',
          vision: true,
        ),
      );
      await host(tester, width, initialize: false);
      final tab = find.text('预设').first;
      await tester.ensureVisible(tab);
      await tester.tap(tab);
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑预设').first);
      await tester.pumpAndSettle();
      final caption = find.widgetWithText(
        DropdownButtonFormField<String>,
        '图片转述模型',
      );
      await tester.ensureVisible(caption);
      await tester.tap(caption);
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试视觉模型 · vision-model').last);
      await tester.pumpAndSettle();
      for (final name in ['网页搜索 · Bing', '显示思考内容', '分多条消息回复']) {
        final field = find.widgetWithText(SwitchListTile, name);
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
      }
      final advanced = find.text('高级设置');
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      final size = find.widgetWithText(TextField, '输入图片最大边长（像素）');
      await tester.ensureVisible(size);
      await tester.enterText(size, '768');
      final count = find.widgetWithText(TextField, '每轮最多发送几条');
      await tester.ensureVisible(count);
      await tester.enterText(count, '4');
      final interval = find.widgetWithText(TextField, '分条发送间隔（毫秒）');
      await tester.ensureVisible(interval);
      await tester.enterText(interval, '800');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final settings = agent.presets.first;
      expect(settings.imageDescriptionProviderId, 'vision');
      expect(settings.imageMaxEdge, 768);
      expect(settings.webSearchEnabled, true);
      expect(settings.showReasoning, true);
      expect(settings.timeAwareness, true);
      expect(settings.multiMessageReply, true);
      expect(settings.readMessageContext, true);
      expect(settings.maxReplyMessages, 4);
      expect(settings.replyIntervalMs, 800);
      // The demo connection uses the edited assistant preset.
      await agent.store.append(
        AgentMessage(
          id: 'ai-feature',
          sessionKey: session.key,
          senderId: '10001',
          senderName: '我',
          outgoing: true,
          source: 'ai',
          segments: [textSegment('AI 最终回复')],
          reasoning: '接口实际返回的内容，不发送给 QQ',
        ),
      );
      await host(
        tester,
        width,
        initialize: false,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: agent,
            builder: (_, _) => AgentChat(agent: agent, sessionKey: session.key),
          ),
        ),
      );
      expect(find.byType(AgentReasoning), findsOneWidget);
      await tester.ensureVisible(find.text('思考内容'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('思考内容'));
      await tester.pumpAndSettle();
      expect(find.text('接口实际返回的内容，不发送给 QQ'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await agent.savePreset(
        AgentPreset.fromJson({...settings.toJson(), 'showReasoning': false}),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AgentReasoning), findsNothing);
      expect(tester.takeException(), isNull);
    });
    agentTest('Agent $width 宽度导航、各管理页和编辑器不溢出', (tester) async {
      await host(tester, width);
      expect(find.text('Agent 体验群'), findsOneWidget);
      for (final label in ['机器人连接', 'AI 模型', '预设', 'AI 插件', 'Skills', '运行日志']) {
        final tab = find.text(label).first;
        await tester.ensureVisible(tab);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: label);
      }
      final connections = find.text('机器人连接').first;
      await tester.ensureVisible(connections);
      await tester.tap(connections);
      await tester.pumpAndSettle();
      await tester.tap(find.text('配置'));
      await tester.pumpAndSettle();
      expect(find.text('配置机器人连接'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      final skills = find.text('Skills').first;
      await tester.ensureVisible(skills);
      await tester.tap(skills);
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑源码 / 配置').first);
      await tester.pumpAndSettle();
      expect(find.text('扩展 JSON / YAML'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }
  agentTest('官机引用保持行内展开，聊天记录进入独立阅读页，折叠后重建不异常', (tester) async {
    await prepare();
    Widget reader(Json body) => Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: AgentSegments(
            segments: [
              {'type': 'qq_body', 'data': officialBodyData(body)},
            ],
            agent: agent,
            connectionId: 'demo',
            storageKey: 'stable-message',
          ),
        ),
      ),
    );
    final quote = {
      'message_type': 103,
      'content': '请解释原文',
      'msg_elements': [
        {
          'content': '引用中的文字',
          'author': {'id': '30003', 'username': '引用作者'},
        },
      ],
    };
    await host(tester, 390, initialize: false, child: reader(quote));
    expect(find.byKey(const ValueKey('quoted-message')), findsOneWidget);
    expect(find.byKey(const ValueKey('forwarded-record-card')), findsNothing);
    expect(find.text('引用作者'), findsOneWidget);
    await tester.tap(find.text('引用消息 · 1 个元素'));
    await tester.pumpAndSettle();
    await host(tester, 390, initialize: false, child: reader(quote));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('引用消息 · 1 个元素'));
    await tester.pumpAndSettle();
    expect(find.text('引用作者'), findsOneWidget);
    await host(
      tester,
      390,
      initialize: false,
      child: reader({
        'message_type': 102,
        'record_title': '群内讨论',
        'msg_elements': [
          {
            'content': '聊天记录的原文',
            'author': {'username': '记录作者'},
          },
        ],
      }),
    );
    await tester.tap(find.byKey(const ValueKey('forwarded-record-card')));
    await tester.pumpAndSettle();
    expect(find.byType(ForwardedRecordScreen), findsOneWidget);
    expect(find.text('记录作者'), findsOneWidget);
    expect(find.text('聊天记录的原文'), findsOneWidget);
    await tester.tap(find.byTooltip('返回原聊天'));
    await tester.pumpAndSettle();
    expect(find.byType(ForwardedRecordScreen), findsNothing);
    expect(agent.connected('demo'), true);
    expect(tester.takeException(), isNull);
  });
  agentTest('AI失败在聊天显示完整原因，可查看详情和关闭，日志保留失败阶段', (tester) async {
    await prepare();
    await host(
      tester,
      390,
      initialize: false,
      child: Scaffold(
        body: ListenableBuilder(
          listenable: agent,
          builder: (_, _) => AgentChat(agent: agent, sessionKey: session.key),
        ),
      ),
    );
    await agent.regenerate(session.key);
    await tester.pumpAndSettle();
    expect(agent.replyState(session.key)['error'], true);
    expect(
      agent.replyState(session.key)['message'],
      contains('请先为当前 AI 预设选择模型配置'),
    );
    final error = find.text(text(agent.replyState(session.key)['message']));
    expect(error, findsOneWidget);
    await tester.tap(error);
    await tester.pumpAndSettle();
    expect(find.text('AI 回复状态'), findsOneWidget);
    expect(error, findsNWidgets(2));
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('隐藏回复状态'));
    await tester.pumpAndSettle();
    expect(error, findsNothing);
    expect(jsonEncode(agent.logs), contains('模型配置'));
    expect(tester.takeException(), isNull);
  });
  agentTest('Agent 会话输入 Enter 发送、Ctrl+Enter 换行；复制不跳动', (tester) async {
    await prepare();
    await host(
      tester,
      800,
      initialize: false,
      child: Scaffold(
        body: ListenableBuilder(
          listenable: agent,
          builder: (_, _) => AgentChat(agent: agent, sessionKey: session.key),
        ),
      ),
    );
    final input = find.byType(TextField).last;
    await tester.tap(input);
    await tester.enterText(input, '第一行');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '第一行\n');
    expect(transport.sent, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(transport.sent, hasLength(1));
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scroll.position.jumpTo(200);
    await tester.pumpAndSettle();
    final before = scroll.position.pixels;
    final visible = find.text('这是一条独立 Agent 会话的演示消息 4');
    await tester.ensureVisible(visible);
    await tester.pumpAndSettle();
    final atCopy = scroll.position.pixels;
    await tester.longPress(visible);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制消息'));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(atCopy, 1));
    expect(before, greaterThan(0));
    transport.onEvent?.call({
      'post_type': 'message',
      'self_id': '10001',
      'message_type': 'group',
      'group_id': '20002',
      'user_id': '30003',
      'message_id': 'new',
      'sender': {'nickname': '新成员'},
      'message': [textSegment('新消息')],
    });
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(atCopy, 1));
    expect(find.text('1 条新消息'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  agentTest('编辑会话和返回不会更换 OneBot 连接或混入官方消息', (tester) async {
    await host(tester, 390);
    await tester.tap(find.text('Agent 体验群'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentChat), findsOneWidget);
    await tester.tap(find.byTooltip('Agent 会话设置'));
    await tester.pumpAndSettle();
    expect(find.text('长期备注 / 会话记忆'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回 Agent 会话'));
    await tester.pumpAndSettle();
    expect(agent.connection('demo')!.selfId, '10001');
    expect(agent.connected('demo'), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  agentTest('日志刷新不重读聊天历史，新消息正常刷新且保留阅读位置', (tester) async {
    final store = UiCountingStore();
    await prepare(store: store);
    await host(tester, 1280, initialize: false);
    await tester.tap(find.text('Agent 体验群'));
    await tester.pumpAndSettle();
    store.historyReads = 0;
    for (var i = 0; i < 30; i++) {
      transport.onDiagnostic?.call('info', '性能测试日志');
    }
    await tester.pumpAndSettle();
    expect(store.historyReads, 0);
    transport.onEvent?.call({
      'post_type': 'message',
      'self_id': '10001',
      'message_type': 'group',
      'group_id': '20002',
      'user_id': '30003',
      'message_id': 'perf-new',
      'sender': {'nickname': '测试成员'},
      'message': [textSegment('历史版本改变后的新消息')],
    });
    await tester.pumpAndSettle();
    expect(store.historyReads, greaterThan(0));
    expect(find.text('1 条新消息'), findsOneWidget);
    final reads = store.historyReads;
    transport.onDiagnostic?.call('info', '后续性能测试日志');
    await tester.pumpAndSettle();
    expect(store.historyReads, reads);
    expect(tester.takeException(), isNull);
  });
  agentTest('连接方式实际切换正反向字段，保存后可切换 QQBot 凭证', (tester) async {
    await host(tester, 390);
    final tab = find.text('机器人连接').first;
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
    expect(find.text('正向 WS 地址'), findsOneWidget);
    expect(find.text('反向监听 IP'), findsNothing);
    Future<void> choice(String label, String option) async {
      final f = find.widgetWithText(DropdownButtonFormField<String>, label);
      await tester.ensureVisible(f);
      await tester.tap(f);
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    await choice('连接方式', '反向 WS · 应用监听端口');
    expect(find.text('正向 WS 地址'), findsNothing);
    expect(find.text('反向监听 IP'), findsOneWidget);
    final path = find.widgetWithText(TextField, '反向 WS 路径');
    await tester.ensureVisible(path);
    await tester.enterText(path, '/');
    await choice('连接方式', '正向 WS · 连接协议端');
    expect(find.text('反向监听端口'), findsNothing);
    expect(find.text('正向 WS 地址'), findsOneWidget);
    await choice('连接方式', '反向 WS · 应用监听端口');
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '反向 WS 路径'))
          .controller!
          .text,
      '/',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(agent.connection('demo')!.mode, 'reverse');
    expect(agent.connection('demo')!.path, '/');
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
    await choice('机器人类型', 'QQBot · 官方机器人');
    expect(find.text('连接方式'), findsNothing);
    expect(find.text('机器人 QQ 号'), findsNothing);
    expect(find.text('QQBot AppID'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'QQBot AppID'),
      '10000001',
    );
    final secret = find.widgetWithText(TextField, 'QQBot ClientSecret');
    await tester.ensureVisible(secret);
    await tester.enterText(secret, 'fixture-only-secret');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(agent.connection('demo')!.protocol, 'qqbot');
    expect(agent.connection('demo')!.selfId, '10000001');
    expect(agent.sessions('demo'), isEmpty);
    expect(
      jsonEncode(agent.snapshot()),
      isNot(contains('fixture-only-secret')),
    );
    expect(tester.takeException(), isNull);
  });
  agentTest('Agent workspace preview artifact', (tester) async {
    final key = GlobalKey();
    await host(
      tester,
      1280,
      child: RepaintBoundary(key: key, child: const AgentWorkspace()),
    );
    await tester.tap(find.text('Agent 体验群'));
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/agent-previews');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/agent-desktop-test.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  agentTest('QQBot 扫码授权只保存到 Agent，确认前不发起扫码', (tester) async {
    final service = AgentQrFixture();
    await host(
      tester,
      390,
      child: AgentWorkspace(qrServiceFactory: () => service),
    );
    final tab = find.text('机器人连接').first;
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();
    await tester.tap(find.text('QQBot 扫码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成登录二维码'));
    await tester.pumpAndSettle();
    expect(service.phase, QrLoginPhase.idle);
    expect(find.textContaining('授权会重置该机器人的密钥'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(agent.connections, hasLength(1));
    await tester.tap(find.text('生成登录二维码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已了解，继续扫码'));
    await tester.pumpAndSettle();
    final official = agent.connections.firstWhere((c) => c.isOfficial);
    expect(official.selfId, '10000001');
    expect(agent.connected(official.id), isTrue);
    expect(agent.connection('demo')!.selfId, '10001');
    expect(service.phase, QrLoginPhase.saved);
    expect(find.textContaining('agent-qr-fixture-secret'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
  });
}
