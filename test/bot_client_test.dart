import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/services/api_service.dart';

import 'support/fakes.dart';

class FailedLoginStorage extends MemoryStorage {
  FailedLoginStorage() : super(config: validConfig());
  @override
  Future<void> saveBotConfig(BotConfig config) async =>
      throw StateError('fixture disk failure');
}

class DelayedLoginApi extends RecordingApi {
  final tokenResults = <Completer<ApiResult<AccessTokenResult>>>[];
  @override
  Future<ApiResult<AccessTokenResult>> getAccessToken({
    required String appId,
    required String clientSecret,
  }) {
    final pending = Completer<ApiResult<AccessTokenResult>>();
    tokenResults.add(pending);
    return pending.future;
  }
}

void main() {
  late MemoryStorage storage;
  late RecordingApi api;
  late TestGateway gateway;
  late BotClient bot;

  setUp(() {
    storage = MemoryStorage(config: validConfig());
    api = RecordingApi();
    gateway = TestGateway();
    bot = BotClient(storage, apiService: api, webSocketService: gateway);
  });
  tearDown(() => bot.dispose());
  test('Agent 连接占用同 AppID 时，原工作区在网络请求前停止连接', () async {
    bot.connectionGuard = (_) => '这个 AppID 正在 QQ Agent 中运行';
    expect(await bot.connect(), isFalse);
    expect(bot.isConnecting, isFalse);
    expect(bot.connectionError, contains('QQ Agent'));
    expect(gateway.connectionRequested, isFalse);
  });

  test('回复序号按原消息分别递增，切回旧消息不会重复使用序号', () async {
    final a = incoming('a');
    final b = incoming('b');
    await storage.saveMessage(a);
    await storage.saveMessage(b);
    await bot.sendTextMessage('group-1', '第一条', isGroup: true, replyTo: a);
    await bot.sendMarkdownMessage(
      'group-1',
      '# 第二条',
      isGroup: true,
      replyTo: b,
    );
    await bot.sendMarkdownMessage(
      'group-1',
      '# 第三条',
      isGroup: true,
      replyTo: a,
    );
    expect(api.calls.map((c) => (c['msgId'], c['msgSeq'])).toList(), [
      ('a', 1),
      ('b', 1),
      ('a', 2),
    ]);
    bot.dispose();
    bot = BotClient(storage, apiService: api, webSocketService: TestGateway());
    await bot.sendTextMessage('group-1', '重启后回复', isGroup: true, replyTo: a);
    expect(api.calls.last['msgSeq'], 3);
  });

  test('并发发送时只刷新一次过期凭证，每条消息都使用新凭证', () async {
    bot.config.tokenExpiresAt = 1;
    await Future.wait([
      bot.sendTextMessage('user', '你好'),
      bot.sendMarkdownMessage('user', '# 你好'),
    ]);
    expect(api.tokenRequests, 1);
    expect(api.calls.map((c) => c['token']), everyElement('refreshed-token'));
  });

  test('保存同账号配置保留凭证，切换账号清除旧凭证', () async {
    await bot.updateConfig(
      BotConfig(
        appId: 'test-app',
        clientSecret: 'test-secret',
        enableAutoReply: true,
      ),
    );
    expect(bot.config.accessToken, 'valid-token');
    await bot.updateConfig(
      BotConfig(appId: 'another-app', clientSecret: 'another-secret'),
    );
    expect(bot.config.accessToken, isEmpty);
  });

  test('新凭据落盘失败不替换当前账号、密钥或 Token', () async {
    final failed = FailedLoginStorage();
    final client = BotClient(
      failed,
      apiService: RecordingApi(),
      webSocketService: TestGateway(),
    );
    addTearDown(client.dispose);
    await expectLater(
      client.updateConfig(
        BotConfig(appId: 'new-app', clientSecret: 'new-secret'),
      ),
      throwsStateError,
    );
    expect(client.config.appId, 'test-app');
    expect(client.config.clientSecret, 'test-secret');
    expect(client.config.accessToken, 'valid-token');
    expect(failed.config.appId, 'test-app');
  });

  test('扫码切换期间旧 Token 结果不能覆盖新凭据或清空新的并发刷新', () async {
    final isolated = MemoryStorage(config: validConfig()..tokenExpiresAt = 1);
    final delayed = DelayedLoginApi();
    final client = BotClient(
      isolated,
      apiService: delayed,
      webSocketService: TestGateway(),
    );
    addTearDown(client.dispose);
    final oldSend = client.sendTextMessage('user', 'old');
    await Future<void>.delayed(Duration.zero);
    expect(delayed.tokenResults, hasLength(1));
    await client.updateConfig(
      BotConfig(appId: '100000001', clientSecret: 'new-fixture-secret'),
    );
    final first = client.sendTextMessage('user', 'new-1');
    await Future<void>.delayed(Duration.zero);
    expect(delayed.tokenResults, hasLength(2));
    delayed.tokenResults[0].complete(
      ApiResult.success(
        AccessTokenResult(accessToken: 'old-fixture-token', expiresIn: 7200),
      ),
    );
    expect(await oldSend, isFalse);
    final second = client.sendTextMessage('user', 'new-2');
    await Future<void>.delayed(Duration.zero);
    expect(delayed.tokenResults, hasLength(2));
    delayed.tokenResults[1].complete(
      ApiResult.success(
        AccessTokenResult(accessToken: 'new-fixture-token', expiresIn: 7200),
      ),
    );
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(
      delayed.calls.map((item) => item['token']),
      everyElement('new-fixture-token'),
    );
    expect(isolated.config.appId, '100000001');
    expect(isolated.config.accessToken, 'new-fixture-token');
  });

  test('过期群消息和机器人自己发的消息不会作为被动回复来源', () async {
    final old = incoming(
      'expired',
      timestamp: DateTime.now().subtract(const Duration(minutes: 6)),
    );
    expect(
      await bot.sendMarkdownMessage(
        'group-1',
        '# 回复',
        isGroup: true,
        replyTo: old,
      ),
      isFalse,
    );
    expect(bot.lastSendError, contains('回复期限'));
    bot.addLocalBotMessage('group-1', '本地消息', 0);
    expect(
      await bot.sendTextMessage(
        'group-1',
        '回复自己',
        isGroup: true,
        replyTo: bot.messages.single,
      ),
      isFalse,
    );
    expect(api.calls, isEmpty);
  });

  test('新实例从历史找回回复来源，单条群消息最多成功回复五次', () async {
    await storage.saveMessage(incoming('received'));
    for (var i = 0; i < 5; i++) {
      expect(
        await bot.sendTextMessage('group-1', '回复 $i', isGroup: true),
        isTrue,
      );
    }
    expect(
      await bot.sendTextMessage('group-1', '超限回复', isGroup: true),
      isFalse,
    );
    expect(api.calls, hasLength(5));
    expect(bot.lastSendError, contains('次数已用完'));
  });

  test('重复网关事件只保存一次且不会再次触发插件', () async {
    var received = 0;
    bot.onMessageReceived = (_) => received++;
    final event = {
      'id': 'incoming-id',
      'sessionId': 'group-1',
      'senderId': 'member',
      'senderName': '用户',
      'content': '你好',
      'isGroup': true,
      'timestamp': DateTime.now(),
    };
    gateway.events.add(event);
    gateway.events.add(event);
    await Future<void>.delayed(Duration.zero);
    expect(received, 1);
    expect(bot.messages, hasLength(1));
  });

  test('发送失败不写入成功气泡，重试不会重复回复序号', () async {
    final source = incoming('source');
    api.failSend = true;
    expect(
      await bot.sendMarkdownMessage(
        'group-1',
        '# 测试',
        isGroup: true,
        replyTo: source,
      ),
      isFalse,
    );
    expect(bot.messages, isEmpty);
    api.failSend = false;
    expect(
      await bot.sendMarkdownMessage(
        'group-1',
        '# 测试',
        isGroup: true,
        replyTo: source,
      ),
      isTrue,
    );
    expect(api.calls.last['msgSeq'], 2);
  });

  test('平台明确拒绝代码块语法时保留原文用文本补发，内容违规不会触发补发', () async {
    const code = '```python\nif True:\n    print("你好")\n```';
    api.markdownErrorCode = 40034011;
    expect(
      await bot.sendMarkdownMessage(
        'group-1',
        code,
        isGroup: true,
        replyTo: incoming('source'),
      ),
      isTrue,
    );
    expect(api.calls.map((c) => c['type']), [2, 0]);
    expect(api.calls.last['content'], code);
    expect(api.calls.last['msgSeq'], 2);
    expect(bot.messages.single.messageType, 0);
    api.markdownErrorCode = 40034006;
    expect(
      await bot.sendMarkdownMessage(
        'group-1',
        code,
        isGroup: true,
        replyTo: incoming('other-source'),
      ),
      isFalse,
    );
    expect(api.calls, hasLength(3));
  });
}
