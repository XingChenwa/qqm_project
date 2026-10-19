// Local-only browser QA fixture. No QQ connection or real account is used.
import 'dart:convert';
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/runtime/assets_server.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import '../server/src/manager_server.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || !args.single.contains('qqm-server-browser-')) {
    throw StateError('仅用于指定临时目录的离线界面测试');
  }
  final directory = Directory(args.single);
  Hive.init(directory.path);
  rootBundle.root = Directory.current;
  final storage = StorageService();
  await storage.init();
  await storage.saveBotConfig(
    BotConfig(
      appId: '10000001',
      clientSecret: 'offline-fixture-only',
      enableOiapiNickname: false,
    ),
  );
  storage.selectChatAccount('10000001');
  for (final (id, name, type) in [
    ('group-a', '机器人开发交流群', 1),
    ('user-a', '薯条同学', 0),
  ]) {
    await storage.saveSession(
      ChatSession(
        id: id,
        name: name,
        sessionType: type,
        lastMessage: '让灵感变成新玩法 ✦',
        lastMessageTime: DateTime.now(),
        unreadCount: type == 0 ? 2 : 0,
      ),
    );
  }
  for (var index = 0; index < 30; index++) {
    await storage.saveMessage(
      MessageModel(
        id: 'fixture-$index',
        sessionId: 'group-a',
        senderId: index.isOdd ? 'bot' : 'member-a',
        senderName: index.isOdd ? '小助手' : '薯条同学',
        content: index == 28
            ? '今天的插件也可以在网页里编辑了吗？'
            : index == 29
            ? '可以的！修改源码、保存并安装，再手动启用就好。'
            : '这是一条离线演示消息 ${index + 1}，不是实际的 QQ 聊天。',
        messageType: 0,
        isFromBot: index.isOdd,
        timestamp: DateTime.now().subtract(Duration(minutes: 30 - index)),
      ),
    );
  }
  final manager = PluginManager(storage);
  await manager.init();
  final server = await ManagerServer.start(
    bot: BotClient(storage),
    plugins: manager,
    storage: storage,
    data: directory,
    assets: Directory.current,
    port: 0,
  );
  stdout.writeln('QQM_PREVIEW_URI=${server.address}');
  await stdin.transform(utf8.decoder).first;
  await server.close();
  await Hive.close();
}
