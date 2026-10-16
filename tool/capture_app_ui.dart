// Captures the real desktop app with in-memory, explicitly labelled demo data.
// It never opens Hive/preferences, reads credentials, connects QQ or checks updates.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/app.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/services/desktop_window_controller.dart';
import 'package:qq_bot_manager/services/storage_service.dart';

class _OfflineNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Screenshot capture is offline; network is disabled.');
}

class _CaptureStorage extends StorageService {
  BotConfig config = BotConfig(
    autoReconnect: false,
    enableOiapiNickname: false,
    skipCloseConfirmation: true,
  );
  final sessions = <ChatSession>[];
  final messages = <MessageModel>[];
  final plugins = <String, PluginInfo>{};
  final pluginData = <String, Map<String, dynamic>>{};
  bool dark = false;

  @override
  Future<void> init() async {}
  @override
  BotConfig getBotConfig() => BotConfig.fromMap(config.toMap());
  @override
  Future<void> saveBotConfig(BotConfig value) async => config = value;
  @override
  List<ChatSession> getSessions() => List.of(sessions);
  @override
  Future<void> saveSession(ChatSession session) async {
    sessions.removeWhere((item) => item.id == session.id);
    sessions.add(session);
  }

  @override
  Future<void> markSessionRead(String id) async {}
  @override
  List<MessageModel> getMessages(String id) =>
      messages.where((item) => item.sessionId == id).toList();
  @override
  MessageModel? getMessageById(String id) =>
      messages.where((item) => item.id == id).firstOrNull;
  @override
  Future<void> saveMessage(MessageModel message) async => messages.add(message);
  @override
  List<PluginInfo> getPluginConfigs() => plugins.values.toList();
  @override
  Future<void> savePluginConfig(PluginInfo plugin) async =>
      plugins[plugin.id] = plugin;
  @override
  Future<Map<String, dynamic>> readPluginData(String scope) async =>
      pluginData[scope] ?? {};
  @override
  Future<void> writePluginData(
    String scope,
    Map<String, dynamic> value,
  ) async => pluginData[scope] = value;
  @override
  List<EmojiItem> getEmojis({String? category}) => [];
  @override
  bool getThemeMode() => dark;
  @override
  Future<void> setThemeMode(bool isDark) async => dark = isDark;
  @override
  Future<void> flush() async {}
}

_CaptureStorage _exampleData() {
  final storage = _CaptureStorage();
  final now = DateTime.now();
  storage.sessions.addAll([
    ChatSession(
      id: 'example-developers',
      name: '开发交流群（示例）',
      sessionType: 1,
      lastMessageTime: now,
      lastMessage: '可以，在插件工作台编写自己的玩法。',
      isPinned: true,
      profileStatus: '离线示例会话 · 不连接 QQ',
      profileUpdatedAt: now,
    ),
    ChatSession(
      id: 'example-friend',
      name: '小明（示例）',
      sessionType: 0,
      lastMessageTime: now.subtract(const Duration(minutes: 12)),
      lastMessage: '天气、翻译、签到和投票，都能在插件里找到。',
    ),
    ChatSession(
      id: 'example-games',
      name: '机器人游乐场（示例）',
      sessionType: 1,
      lastMessageTime: now.subtract(const Duration(minutes: 35)),
      lastMessage: '/投票 创建 周末活动 | 露营 | 看电影',
      unreadCount: 2,
      profileUpdatedAt: now,
    ),
  ]);
  final examples = <({String name, bool bot, int type, String content})>[
    (name: '小明（示例）', bot: false, type: 0, content: '这个客户端可以做什么？'),
    (
      name: '机器人（示例）',
      bot: true,
      type: 2,
      content:
          '### QQ 机器人管理器\n'
          '群聊与单聊统一管理，消息和插件都在一个工作台。\n\n'
          '- **Markdown** 独立编辑、预览与发送\n'
          '- 天气、翻译、骰子、签到和群内投票\n'
          '- JSON / YAML 与 HTTP 插件扩展',
    ),
    (name: '小明（示例）', bot: false, type: 0, content: '我也可以开发自己的插件吗？'),
    (
      name: '机器人（示例）',
      bot: true,
      type: 0,
      content:
          '可以，在插件工作台编辑文件、检查规则并安装自己的玩法。\n'
          '以上是离线示例消息，不连接真实 QQ。',
    ),
  ];
  for (final (index, example) in examples.indexed) {
    storage.messages.add(
      MessageModel(
        id: 'example-message-$index',
        sessionId: 'example-developers',
        senderId: example.bot ? 'example-bot' : 'example-member',
        senderName: example.name,
        content: example.content,
        markdownContent: example.type == 2 ? example.content : null,
        messageType: example.type,
        timestamp: now.subtract(Duration(minutes: examples.length - index)),
        isFromBot: example.bot,
        isRead: true,
      ),
    );
  }
  return storage;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) exit(64);
  HttpOverrides.global = _OfflineNetwork();
  final storage = _exampleData();
  final manager = PluginManager(storage);
  await manager.init();
  final bot = BotClient(storage);
  final window = DesktopWindowController(
    storage,
    beforeExit: () async {
      bot.dispose();
      manager.dispose();
    },
  );
  await window.initialize();
  if (!window.ready) throw StateError(window.error);
  final boundaryKey = GlobalKey();
  runApp(
    RepaintBoundary(
      key: boundaryKey,
      child: MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<BotClient>.value(value: bot),
          ChangeNotifierProvider<PluginManager>.value(value: manager),
          ChangeNotifierProvider<DesktopWindowController>.value(value: window),
        ],
        child: const QQBotManagerApp(),
      ),
    ),
  );
  final timeout = Timer(const Duration(seconds: 30), () => exit(1));
  try {
    await Future<void>.delayed(const Duration(seconds: 2));
    await WidgetsBinding.instance.endOfFrame;
    final render =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/ui-runtime-capture/client-chat.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    stdout.writeln(
      'Captured native Flutter app: ${image.width}x${image.height}; '
      'offline sample data; no credentials or QQ connection.',
    );
    image.dispose();
  } finally {
    timeout.cancel();
    await window.exitApp();
  }
}
