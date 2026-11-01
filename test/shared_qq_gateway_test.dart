import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/qqbot.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/official_workspace_link.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/official_reply_sequences.dart';
import 'package:qq_bot_manager/services/shared_qq_gateway.dart';
import 'support/fakes.dart';
import 'websocket_service_test.dart' as ws;
import 'agent_qqbot_test.dart' as qq;

class SharedFixtureApi extends RecordingApi {
  final String url;
  SharedFixtureApi(this.url);
  @override
  Future<ApiResult<String>> getGatewayUrl({
    required String baseUrl,
    required String accessToken,
  }) async => ApiResult.success(url);
}

class SharedFixtureStorage extends MemoryStorage {
  final counters = <String, int>{};
  SharedFixtureStorage({required super.config});
  @override
  int officialReplySequence(String key) => counters[key] ?? 0;
  @override
  Future<void> saveOfficialReplySequence(String key, int value) async {
    counters[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  for (final first in ['工作台', 'Agent']) {
    test('$first 先连接：同AppID只鉴权一次，双方各收一次，停止一边另一边继续', () async {
      final server = await ws.LocalGateway.start();
      final pool = OfficialQqGatewayPool();
      final a = pool.client(
        scope: () => officialQqScope('100001', 'https://api.bot.qq.com'),
      );
      final b = pool.client(
        scope: () => officialQqScope('100001', 'https://api.bot.qq.com/'),
      );
      final left = <Map<String, dynamic>>[], right = <Map<String, dynamic>>[];
      var readyA = 0, readyB = 0;
      a.messageStream.listen(left.add);
      b.messageStream.listen(right.add);
      a.onReady = (_) => readyA++;
      b.onReady = (_) => readyB++;
      try {
        final initial = first == '工作台' ? a : b, second = first == '工作台' ? b : a;
        expect(
          await initial.connect(
            wsUrl: server.url,
            accessToken: 'fixture-token',
          ),
          true,
        );
        expect(
          await second.connect(wsUrl: server.url, accessToken: 'fixture-token'),
          true,
        );
        expect(server.sockets.length, 1);
        expect(server.payloads.where((p) => p['op'] == 2).length, 1);
        expect(readyA, 1);
        expect(readyB, 1);
        server.event('GROUP_AT_MESSAGE_CREATE', {
          'id': 'same-message',
          'group_openid': 'GROUP',
          'author': {'id': 'USER'},
          'content': '测试',
        });
        await ws.until(() => left.length == 1 && right.length == 1);
        expect(left.single['id'], 'same-message');
        expect(right.single['id'], 'same-message');
        expect(left.single['_transportGeneration'], a.transportGeneration);
        initial.dispose();
        expect(second.isConnected, true);
        server.event('GROUP_AT_MESSAGE_CREATE', {
          'id': 'next-message',
          'group_openid': 'GROUP',
          'author': {'id': 'USER'},
          'content': '继续',
        });
        await ws.until(() => (first == '工作台' ? right : left).length == 2);
        expect(server.sockets.length, 1);
      } finally {
        a.dispose();
        b.dispose();
        await server.close();
      }
    });
  }

  test('同时连接和取消握手：不会重复开网关，也不会取消其他订阅的鉴权', () async {
    final server = await ws.LocalGateway.start();
    server.sendReady = false;
    final pool = OfficialQqGatewayPool();
    final a = pool.client(scope: () => 'same'),
        b = pool.client(scope: () => 'same');
    try {
      final first = a.connect(wsUrl: server.url, accessToken: 'fixture-token');
      final second = b.connect(wsUrl: server.url, accessToken: 'fixture-token');
      await ws.until(() => server.payloads.any((p) => p['op'] == 2));
      a.disconnect();
      server.ready(server.sockets.single);
      expect(await first, false);
      expect(await second, true);
      expect(b.isConnected, true);
      expect(server.sockets.length, 1);
    } finally {
      a.dispose();
      b.dispose();
      await server.close();
    }
  });

  test('切换AppID使用新网关，原Agent保留连接；正式与沙箱相互隔离', () async {
    final server = await ws.LocalGateway.start();
    final pool = OfficialQqGatewayPool();
    var app = '100001';
    final work = pool.client(
      scope: () => officialQqScope(app, 'https://api.bot.qq.com'),
    );
    final agent = pool.client(
      scope: () => officialQqScope('100001', 'https://api.bot.qq.com'),
    );
    final sandbox = pool.client(
      scope: () =>
          officialQqScope('100001', 'https://sandbox.api.sgroup.qq.com'),
    );
    try {
      expect(
        await work.connect(wsUrl: server.url, accessToken: 'fixture-token'),
        true,
      );
      expect(
        await agent.connect(wsUrl: server.url, accessToken: 'fixture-token'),
        true,
      );
      work.disconnect();
      app = '100002';
      expect(
        await work.connect(wsUrl: server.url, accessToken: 'fixture-other'),
        true,
      );
      expect(agent.isConnected, true);
      expect(
        await sandbox.connect(
          wsUrl: server.url,
          accessToken: 'fixture-sandbox',
        ),
        true,
      );
      expect(server.sockets.length, 3);
    } finally {
      work.dispose();
      agent.dispose();
      sandbox.dispose();
      await server.close();
    }
  });

  test('停止先连接的工作区后，网关仍使用另一边的凭证恢复连接', () async {
    final server = await ws.LocalGateway.start();
    final pool = OfficialQqGatewayPool();
    final work = pool.client(scope: () => 'recovery');
    final agent = pool.client(scope: () => 'recovery');
    var refreshes = 0;
    work.refreshAccessToken = () async => throw StateError('已停止的工作区不应刷新');
    agent.refreshAccessToken = () async {
      refreshes++;
      return 'remaining-workspace-token';
    };
    try {
      await work.connect(
        wsUrl: server.url,
        accessToken: 'fixture-token',
        reconnectInterval: const Duration(milliseconds: 10),
      );
      await agent.connect(
        wsUrl: server.url,
        accessToken: 'fixture-token',
        reconnectInterval: const Duration(milliseconds: 10),
      );
      work.disconnect();
      await server.sockets.single.close(4000, 'fixture reconnect');
      await ws.until(() => server.sockets.length == 2 && agent.isConnected);
      expect(refreshes, 1);
      expect(
        server.payloads.lastWhere((p) => p['op'] == 6)['d']['token'],
        'QQBot remaining-workspace-token',
      );
      expect(server.payloads.where((p) => p['op'] == 2).length, 1);
    } finally {
      work.dispose();
      agent.dispose();
      await server.close();
    }
  });

  test('共享回复序号在交替、并发及重启后递增，AppID、环境与事件分开', () async {
    final values = <String, int>{};
    OfficialReplySequences create() => OfficialReplySequences(
      read: (key) => values[key] ?? 0,
      write: (key, value) async {
        values[key] = value;
      },
    );
    final ledger = create(),
        scope = officialQqScope('100001', 'https://api.bot.qq.com');
    expect(ledger.reserve(scope, 'message:m'), 1);
    expect(ledger.reserve(scope, 'message:m'), 2);
    expect(ledger.reserve(scope, 'event:m'), 1);
    expect(
      ledger.reserve(
        officialQqScope('100002', 'https://api.bot.qq.com'),
        'message:m',
      ),
      1,
    );
    await ledger.settled();
    final restored = create();
    expect(restored.reserve(scope, 'message:m'), 3);
    expect(restored.reserve(scope, 'message:m', minimum: 4, limit: 5), 4);
    expect(restored.reserve(scope, 'message:m', limit: 5), 5);
    expect(
      () => restored.reserve(scope, 'message:m', limit: 5),
      throwsFormatException,
    );
    await restored.settled();
  });

  test('真实BotClient与Agent共用默认网关、独立会话，并交替发送不重复msg_seq', () async {
    final fixture = qq.QqFixture();
    await fixture.open();
    final config = BotConfig(
      appId: '10000001',
      clientSecret: 'fixture-secret',
      apiBaseUrl: fixture.base.toString(),
      accessToken: 'fixture-access-token',
      tokenExpiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      enableOiapiNickname: false,
    );
    final storage = SharedFixtureStorage(config: config);
    final api = SharedFixtureApi(
      'ws://127.0.0.1:${fixture.server.port}/gateway-ws',
    );
    final bot = BotClient(storage, apiService: api);
    late AgentController agent;
    QqBotAgentTransport? transport;
    agent = AgentController(
      store: AgentStore.memory(),
      transportFactory: (c) => transport = QqBotAgentTransport(
        c,
        apiBase: fixture.base,
        tokenEndpoint: fixture.base.resolve('/app/getAppAccessToken'),
        sharedSequences: agent.officialReplySequences,
      ),
    );
    linkOfficialWorkspaces(bot, agent, storage);
    try {
      await agent.initialize();
      await agent.saveConnection(
        AgentConnection(
          id: 'official',
          name: '同AppID',
          selfId: '10000001',
          protocol: 'qqbot',
          clientSecret: 'fixture-secret',
          aiEnabled: false,
          resolveOfficialProfiles: false,
        ),
      );
      expect(await bot.connect(), true);
      await agent.connect('official');
      expect(agent.connected('official'), true);
      expect(fixture.identifies.length, 1);
      fixture.message(
        'shared-source',
        author: {
          'id': 'USER_OPENID',
          'member_openid': 'USER_OPENID',
          'username': '测试用户',
        },
        extra: {'group_name': '测试群'},
      );
      await qq.until(
        () =>
            bot.messages.any((m) => m.id == 'shared-source') &&
            agent.sessions('official').isNotEmpty,
      );
      final source = bot.messages.firstWhere((m) => m.id == 'shared-source');
      expect(
        await bot.sendTextMessage(
          'GROUP_OPENID',
          '工作台',
          isGroup: true,
          replyTo: source,
        ),
        true,
      );
      await transport!.call('send_group_msg', {
        'group_id': 'GROUP_OPENID',
        'message': 'Agent回复',
      });
      expect(api.calls.last['msgSeq'], 1);
      expect(fixture.bodies.last['msg_seq'], 2);
      expect(
        await bot.sendMarkdownMessage(
          'GROUP_OPENID',
          '# 工作台',
          isGroup: true,
          replyTo: source,
        ),
        true,
      );
      expect(api.calls.last['msgSeq'], 3);
      final previousCalls = api.calls.length;
      await Future.wait([
        transport!.call('send_group_msg', {
          'group_id': 'GROUP_OPENID',
          'message': '并发Agent',
        }),
        bot.sendTextMessage(
          'GROUP_OPENID',
          '并发工作台',
          isGroup: true,
          replyTo: source,
        ),
      ]);
      expect(
        {fixture.bodies.last['msg_seq'], api.calls.last['msgSeq']},
        {4, 5},
      );
      expect(
        await bot.sendTextMessage(
          'GROUP_OPENID',
          '额度已用完',
          isGroup: true,
          replyTo: source,
        ),
        false,
      );
      expect(api.calls.length, previousCalls + 1);
      await agent.disconnect('official');
      expect(bot.isConnected, true);
      fixture.message('work-only');
      await qq.until(() => bot.messages.any((m) => m.id == 'work-only'));
      await agent.connect('official');
      expect(fixture.identifies.length, 1);
      bot.disconnect();
      expect(agent.connected('official'), true);
      fixture.message('agent-only');
      await qq.until(
        () => agent.store
            .messages(agent.sessions('official').first.key)
            .any((m) => m.id == 'ob:agent-only'),
      );
    } finally {
      await agent.shutdown();
      bot.dispose();
      await fixture.close();
    }
  });
}
