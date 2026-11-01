import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/wake_sessions.dart';
import 'agent_core_test.dart' as fixtures;

void main() {
  testWidgets('空闲五分钟自动休眠；新成员消息重新计时，各群与连接独立', (tester) async {
    final sleeping = <String>[];
    final wake = AgentWakeSessions(
      clock: tester.binding.clock.now,
      onSleep: (connection, key) => sleeping.add('$connection:$key'),
    );
    addTearDown(wake.close);
    expect(wake.touch('a', 'group-a'), true);
    await tester.pump(const Duration(minutes: 4));
    expect(wake.touch('a', 'group-a'), false);
    wake.touch('b', 'group-b');
    await tester.pump(const Duration(minutes: 4, seconds: 59));
    expect(wake.isAwake('group-a'), true);
    expect(sleeping, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(wake.isAwake('group-a'), false);
    expect(wake.isAwake('group-b'), false);
    expect(sleeping, containsAll(['a:group-a', 'b:group-b']));
    expect(wake.touch('a', 'group-a'), true);
    wake.stopConnection('a');
    await tester.pump(const Duration(minutes: 6));
    expect(sleeping.length, 2);
  });

  for (final protocol in ['onebot', 'qqbot']) {
    group('$protocol 群聊连续唤醒', () {
      late AgentController agent;
      late fixtures.FakeAgentModel model;
      late Map<String, fixtures.FakeAgentTransport> peers;
      late DateTime now;
      var serial = 0;
      setUp(() async {
        now = DateTime(2026, 10, 27, 12);
        peers = {};
        serial = 0;
        model = fixtures.FakeAgentModel();
        agent = AgentController(
          store: AgentStore.memory(),
          model: model,
          clock: () => now,
          transportFactory: (c) => peers[c.id] = fixtures.FakeAgentTransport(c),
        );
        await agent.initialize();
        await agent.saveProvider(
          AgentProvider(
            id: 'model',
            name: 'fixture',
            baseUrl: 'http://127.0.0.1:1/v1',
            model: 'fixture',
            apiKey: 'fixture-only',
          ),
        );
        await agent.savePreset(
          AgentPreset(
            id: 'assistant',
            name: 'fixture',
            prompt: '中文回答',
            providerId: 'model',
          ),
        );
      });
      tearDown(() async {
        await agent.shutdown();
        agent.dispose();
      });
      Future<fixtures.FakeAgentTransport> connect(
        String id,
        String self, {
        Json changes = const {},
      }) async {
        await agent.saveConnection(
          AgentConnection.fromJson({
            ...AgentConnection(
              id: id,
              name: id,
              selfId: self,
              protocol: protocol,
              clientSecret: protocol == 'qqbot' ? 'fixture-only' : '',
              aiEnabled: true,
              cooldownSeconds: 0,
              commandPrefix: '/bot',
              extraWakePrefixes: ['小助手', 'hey bot'],
              resolveOfficialProfiles: false,
            ).toJson(),
            ...changes,
          }),
        );
        await agent.connect(id);
        return peers[id]!;
      }

      Future<void> receive(
        fixtures.FakeAgentTransport peer, {
        String text = '普通聊天',
        bool at = false,
        String group = '20002',
        String user = '30003',
        bool reply = true,
        String? id,
      }) async {
        final before = peer.sent.length;
        final messageId = id ?? 'wake-${++serial}';
        peer.receive(
          id: messageId,
          mention: at,
          content: text,
          peer: group,
          user: user,
        );
        await fixtures.eventually(
          () => agent
              .sessions(peer.config.id)
              .any(
                (s) =>
                    s.peerId == group &&
                    agent.store
                        .messages(s.key)
                        .any((m) => m.id == 'ob:$messageId'),
              ),
        );
        if (reply) {
          await fixtures.eventually(
            () => peer.sent.length == before + 1 && agent.busySessions.isEmpty,
          );
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 45));
          expect(peer.sent.length, before);
        }
      }

      test('@、/ai、自定义命令、额外前缀都能唤醒；跨成员续聊并在空闲五分钟后重新唤醒', () async {
        final peer = await connect('a', '10001');
        await receive(peer, reply: false);
        await receive(peer, text: '/ai 你好');
        await receive(peer, user: '40004');
        final system = (model.requests.last['messages'] as List)
            .where((m) => m['role'] == 'system')
            .map((m) => m['content'])
            .join('\n');
        expect(system, contains('当前群聊已被唤醒'));
        expect(system, contains('没有直接@你'));
        now = now.add(const Duration(minutes: 4));
        await receive(peer, text: '继续');
        now = now.add(const Duration(minutes: 4, seconds: 59));
        await receive(peer, text: '还在吗');
        now = now.add(const Duration(minutes: 5));
        await receive(peer, reply: false);
        expect(jsonEncode(agent.logs), contains('会话未唤醒'));
        await receive(peer, text: '小助手你好');
        await receive(peer);
        now = now.add(const Duration(minutes: 5));
        await receive(peer, text: '你好', at: true);
        await receive(peer);
        now = now.add(const Duration(minutes: 5));
        await receive(peer, text: '/bot 你好');
        await receive(peer);
        now = now.add(const Duration(minutes: 5));
        await receive(peer, text: 'hey bot 你好');
        await receive(peer);
      });

      test('各群和各连接独立；暂时掉线保留有效期限，手动断开与暂停结束连续会话', () async {
        final a = await connect('a', '10001'), b = await connect('b', '10002');
        await receive(a, at: true);
        await receive(a, group: '77777', reply: false);
        await receive(b, reply: false);
        a.online = false;
        a.onState?.call();
        a.online = true;
        a.onState?.call();
        await receive(a);
        await agent.disconnect('a');
        await agent.connect('a');
        await receive(peers['a']!, reply: false);
        await receive(peers['a']!, at: true);
        final s = agent.sessions('a').firstWhere((s) => s.peerId == '20002');
        s.paused = true;
        await agent.configureSession(s);
        await receive(peers['a']!, at: true, reply: false);
        s.paused = false;
        await agent.configureSession(s);
        await receive(peers['a']!, reply: false);
      });

      test('重复事件、机器人回复和白名单外用户都不延长五分钟期限', () async {
        final peer = await connect(
          'a',
          '10001',
          changes: {
            'userAllowlist': ['30003'],
          },
        );
        await receive(peer, at: true, id: 'initial-wake');
        now = now.add(const Duration(minutes: 4, seconds: 50));
        await receive(peer, at: true, id: 'initial-wake', reply: false);
        await receive(peer, at: true, user: '40004', reply: false);
        await receive(peer, user: '10001', at: true, reply: false);
        now = now.add(const Duration(seconds: 10));
        await receive(peer, reply: false);
      });

      test('群聊关闭与AI关闭不被唤醒绕过；冷却中的有效成员消息仍刷新空闲时间', () async {
        final off = await connect(
          'off',
          '10001',
          changes: {'groupTrigger': 'off'},
        );
        await receive(off, at: true, reply: false);
        await receive(off, text: '/ai 你好', reply: false);
        final disabled = await connect(
          'disabled',
          '10002',
          changes: {'aiEnabled': false},
        );
        await receive(disabled, at: true, reply: false);
        await receive(disabled, reply: false);
        final cooling = await connect(
          'cool',
          '10003',
          changes: {'cooldownSeconds': 3600},
        );
        await receive(cooling, at: true);
        now = now.add(const Duration(minutes: 4));
        await receive(cooling, reply: false);
        now = now.add(const Duration(minutes: 4));
        await receive(cooling, reply: false);
        expect(
          agent.replyState(agent.sessions('cool').single.key)['message'],
          contains('冷却'),
        );
      });
    });
  }
}
