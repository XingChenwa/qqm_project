import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'support/fakes.dart';

class DelayedAccountApi extends RecordingApi {
  final requested = Completer<void>();
  final response = Completer<ApiResult<String>>();
  @override
  Future<ApiResult<String>> sendQQMessage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required String content,
    bool isGroup = false,
    String? msgId,
    int? msgSeq,
  }) {
    requested.complete();
    return response.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late StorageService storage;
  final a = validConfig()..appId = '10001';
  final b = validConfig()..appId = '10002';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('qqm-multi-bot-test-');
    Hive.init(directory.path);
    SharedPreferences.setMockInitialValues({
      'bot_config': jsonEncode(a.toMap()),
    });
    storage = StorageService();
    await storage.init();
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('相同会话和消息 ID 也按 AppID 隔离，切回及重启保留独立历史', () async {
    final bot = BotClient(
      storage,
      apiService: RecordingApi(),
      webSocketService: TestGateway(),
    );
    addTearDown(bot.dispose);
    await storage.saveSession(
      ChatSession(
        id: 'same-openid',
        name: 'A 的用户',
        sessionType: 0,
        lastMessageTime: DateTime.now(),
      ),
    );
    await storage.saveMessage(
      incoming('same-id', session: 'same-openid', content: 'A 的聊天'),
    );
    bot.refresh();
    expect(bot.sessions.single.name, 'A 的用户');
    await bot.updateConfig(b);
    expect(bot.sessions, isEmpty);
    expect(bot.getMessagesForSession('same-openid'), isEmpty);
    await storage.saveSession(
      ChatSession(
        id: 'same-openid',
        name: 'B 的用户',
        sessionType: 0,
        lastMessageTime: DateTime.now(),
      ),
    );
    await storage.saveMessage(
      incoming('same-id', session: 'same-openid', content: 'B 的聊天'),
    );
    await bot.switchBot(a.appId);
    expect(bot.sessions.single.name, 'A 的用户');
    expect(bot.getMessagesForSession('same-openid').single.content, 'A 的聊天');
    await bot.switchBot(b.appId);
    expect(bot.sessions.single.name, 'B 的用户');
    expect(bot.getMessagesForSession('same-openid').single.content, 'B 的聊天');
    expect(
      storage.getBotProfiles().map((p) => p.appId),
      containsAll(['10001', '10002']),
    );
    await Hive.close();
    storage = StorageService();
    await storage.init();
    expect(storage.getBotConfig().appId, '10002');
    expect(storage.getMessages('same-openid').single.content, 'B 的聊天');
    expect(storage.getBotProfiles(), hasLength(2));
  });

  test('旧版无命名空间记录只归升级前的 AppID，不复制给新机器人', () async {
    final messages = Hive.box<String>('messages');
    final sessions = Hive.box<String>('sessions');
    await messages.put('legacy', jsonEncode(incoming('legacy').toMap()));
    await sessions.put(
      'group-1',
      jsonEncode(
        ChatSession(
          id: 'group-1',
          name: '旧聊天',
          sessionType: 1,
          lastMessageTime: DateTime.now(),
        ).toMap(),
      ),
    );
    expect(storage.getMessages('group-1'), hasLength(1));
    await storage.saveBotConfig(b);
    // Persisting a new profile alone must not change the in-flight chat owner.
    expect(storage.getMessages('group-1'), hasLength(1));
    storage.selectChatAccount(b.appId);
    expect(storage.getMessages('group-1'), isEmpty);
    expect(storage.getSessions(), isEmpty);
    storage.selectChatAccount(a.appId);
    expect(storage.getSessions().single.name, '旧聊天');
    await storage.markMessageRead('legacy');
    expect(storage.getMessages('group-1'), hasLength(1));
    expect(storage.getMessageById('legacy')!.isRead, isTrue);
    expect(messages.containsKey('legacy'), isTrue);
  });

  test('无法确认归属的旧数据保留但不分配给后来添加的 AppID', () async {
    await Hive.close();
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    await Hive.box<String>(
      'messages',
    ).put('unknown', jsonEncode(incoming('unknown').toMap()));
    await storage.saveBotConfig(a);
    storage.selectChatAccount(a.appId);
    expect(storage.getMessages('group-1'), isEmpty);
    expect(Hive.box<String>('messages').containsKey('unknown'), isTrue);
  });

  test('切换期间迟到的发送不会写入另一 AppID，回复序号互不混用', () async {
    final api = DelayedAccountApi();
    final bot = BotClient(
      storage,
      apiService: api,
      webSocketService: TestGateway(),
    );
    addTearDown(bot.dispose);
    await storage.saveMessage(incoming('original'));
    final pending = bot.sendTextMessage('group-1', 'A 的发送', isGroup: true);
    await api.requested.future;
    await bot.updateConfig(b);
    api.response.complete(ApiResult.success('late-a-message'));
    expect(await pending, isFalse);
    expect(bot.messages, isEmpty);
    expect(storage.getMessages('group-1'), isEmpty);
    final recording = RecordingApi();
    final second = BotClient(
      storage,
      apiService: recording,
      webSocketService: TestGateway(),
    );
    addTearDown(second.dispose);
    await storage.saveMessage(incoming('original'));
    await second.sendTextMessage('group-1', 'B 的发送', isGroup: true);
    expect(recording.calls.last['msgSeq'], 1);
    expect(recording.calls.last['msgId'], 'original');
  });

  test('旧消息对象不能跨 AppID 引用或撤回，旧连接排队事件会被丢弃', () async {
    final gateway = TestGateway();
    final api = RecordingApi();
    final bot = BotClient(storage, apiService: api, webSocketService: gateway);
    addTearDown(bot.dispose);
    await storage.saveMessage(incoming('source'));
    final source = bot.getMessagesForSession('group-1').single;
    final generation = gateway.transportGeneration;
    await bot.updateConfig(b);
    expect(
      await bot.sendTextMessage(
        'group-1',
        '不能跨机器人回复',
        isGroup: true,
        replyTo: source,
      ),
      isFalse,
    );
    expect(api.calls, isEmpty);
    expect(bot.lastSendError, contains('AppID'));
    gateway.events.add({
      'id': 'late',
      'sessionId': 'group-1',
      'senderId': 'old-user',
      'content': '旧连接排队事件',
      '_transportGeneration': generation,
    });
    await Future<void>.delayed(Duration.zero);
    expect(bot.messages, isEmpty);
    expect(storage.getMessages('group-1'), isEmpty);
  });

  test('新的群成员 @ 示例是可导入且限群使用的规则', () async {
    final raw = await File(
      'plugins/examples/group_mentions/plugin.json',
    ).readAsString();
    final manifest = PluginManifest.parse(raw);
    expect(manifest.id, 'group_mentions_demo');
    expect(raw, contains('<qqbot-at-user'));
    expect(raw, contains('"scope": "group"'));
    expect(raw, isNot(contains('qqbot-at-everyone')));
  });
}
