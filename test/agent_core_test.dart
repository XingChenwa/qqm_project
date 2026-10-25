import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:qq_bot_manager/agent/ai.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/defaults.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/onebot.dart';
import 'package:qq_bot_manager/agent/script.dart';
import 'package:qq_bot_manager/agent/store.dart';

class FakeAgentTransport extends AgentTransport {
  final AgentConnection config;
  bool online = false;
  final sent = <Json>[];
  FakeAgentTransport(this.config);
  @override
  bool get connected => online;
  @override
  String get status => online ? '已连接' : '未连接';
  @override
  String get nickname => '测试机器人 ${config.selfId}';
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
    if (action.startsWith('send_')) {
      sent.add({'action': action, ...params});
      return {'message_id': 'sent-${sent.length}'};
    }
    if (action == 'get_friend_list') {
      return [
        {'user_id': 20002, 'nickname': '好友', 'remark': '老朋友'},
      ];
    }
    if (action == 'get_group_list') {
      return [
        {'group_id': 20002, 'group_name': '测试群'},
      ];
    }
    return {};
  }

  void receive({
    String id = '1',
    String kind = 'group',
    String peer = '20002',
    String user = '30003',
    String content = '你好',
    bool mention = true,
    String? self,
  }) {
    onEvent?.call({
      'post_type': 'message',
      'self_id': self ?? config.selfId,
      'message_type': kind,
      if (kind == 'group') 'group_id': peer,
      'user_id': kind == 'private' ? peer : user,
      'message_id': id,
      'sender': {'nickname': '小明'},
      'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'message': [
        if (mention)
          {
            'type': 'at',
            'data': {'qq': config.selfId},
          },
        textSegment(content),
      ],
    });
  }
}

class FakeAgentModel implements AgentModel {
  final requests = <Json>[];
  Future<Json> Function(int, Json)? handler;
  @override
  Future<Json> complete(
    AgentProvider p,
    Json request,
    CancelToken cancel,
  ) async {
    requests.add(object(jsonDecode(jsonEncode(request))));
    return handler == null
        ? answer('测试回复')
        : handler!(requests.length, request);
  }
}

class PausedAgentStore extends AgentStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  PausedAgentStore() : super.memory();
  @override
  Future<bool> append(AgentMessage message) async {
    if (!message.outgoing && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return super.append(message);
  }
}

Json answer(String content) => {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': content},
    },
  ],
  'usage': {'prompt_tokens': 12, 'completion_tokens': 5},
};
Future<void> eventually(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition did not become true');
}

void main() {
  late AgentController agent;
  late FakeAgentModel model;
  late Map<String, FakeAgentTransport> transports;
  setUp(() async {
    model = FakeAgentModel();
    transports = {};
    agent = AgentController(
      store: AgentStore.memory(),
      model: model,
      transportFactory: (c) => transports[c.id] = FakeAgentTransport(c),
    );
    await agent.initialize();
    await agent.saveProvider(
      AgentProvider(
        id: 'model',
        name: '本地测试',
        baseUrl: 'http://127.0.0.1:9999/v1',
        model: 'offline',
        apiKey: 'fixture-api-key',
      ),
    );
    await agent.savePreset(
      AgentPreset(
        id: 'assistant',
        name: '测试',
        prompt: '回答问题',
        providerId: 'model',
      ),
    );
  });
  tearDown(() async {
    await agent.shutdown();
    agent.dispose();
  });
  Future<FakeAgentTransport> connect(
    String id,
    String self, {
    bool ai = true,
    String trigger = 'mention',
    List<String> plugins = const [],
    List<String> groups = const [],
  }) async {
    await agent.saveConnection(
      AgentConnection(
        id: id,
        name: id,
        selfId: self,
        aiEnabled: ai,
        cooldownSeconds: 0,
        groupTrigger: trigger,
        pluginIds: plugins,
        groupAllowlist: groups,
      ),
    );
    await agent.connect(id);
    return transports[id]!;
  }

  test('默认示例关闭，预设可用，不自动连接或调用 AI', () {
    expect(agent.connections, isEmpty);
    expect(model.requests, isEmpty);
    expect(agent.presets.length, 4);
    expect(agent.extensions.every((e) => !e.enabled), isTrue);
  });
  test('QQ 号验证拒绝超出整数范围的标识', () {
    expect(qqId('10001'), isTrue);
    expect(qqId('10000000000'), isTrue);
    expect(qqId('9999999999999999999'), isFalse);
    expect(qqId('openid-not-a-qq'), isFalse);
  });
  test('消息写入期间切换实际 QQ 账号，旧事件不会触发新账号回复', () async {
    final store = PausedAgentStore();
    final peers = <String, FakeAgentTransport>{};
    final localModel = FakeAgentModel();
    final local = AgentController(
      store: store,
      model: localModel,
      transportFactory: (c) => peers[c.selfId] = FakeAgentTransport(c),
    );
    try {
      await local.initialize();
      await local.saveProvider(agent.providers.single);
      await local.savePreset(
        agent.presets.firstWhere((p) => p.id == 'assistant'),
      );
      for (final self in ['10001', '10002']) {
        await local.saveConnection(
          AgentConnection(
            id: 'same-profile',
            name: '账号切换',
            selfId: self,
            aiEnabled: true,
          ),
        );
        await local.connect('same-profile');
        if (self == '10001') {
          peers[self]!.receive(content: '旧账号延迟到达的消息');
          await store.entered.future;
        }
      }
      store.release.complete();
      await store.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(localModel.requests, isEmpty);
      expect(local.sessions(), isEmpty);
      expect(peers['10002']!.sent, isEmpty);
      peers['10002']!.receive(content: '新账号的消息');
      await eventually(() => peers['10002']!.sent.isNotEmpty);
      expect(jsonEncode(localModel.requests), isNot(contains('旧账号延迟')));
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await local.shutdown();
      local.dispose();
    }
  });
  test('编辑会话设置保留编辑期间新增的未读和最后活动时间', () async {
    final t = await connect('a', '10001', ai: false);
    final draft = await agent.openSession('a', 'group', '20002');
    t.receive();
    await eventually(() => agent.session(draft.key)!.unread == 1);
    final latest = agent.session(draft.key)!;
    draft.memory = '新的会话备注';
    await agent.configureSession(draft);
    expect(agent.session(draft.key)!.unread, 1);
    expect(agent.session(draft.key)!.updated, latest.updated);
  });
  test('相同群号、私聊 QQ 和不同 OneBot 账号完全隔离', () async {
    final a = await connect('a', '10001', ai: false),
        b = await connect('b', '10002', ai: false);
    a.receive(content: '机器人 A 群消息');
    b.receive(content: '机器人 B 群消息');
    a.receive(kind: 'private', content: 'A 的私聊');
    await eventually(() => agent.sessions().length == 3);
    expect(agent.sessions().map((s) => s.key).toSet().length, 3);
    for (final s in agent.sessions()) {
      await eventually(() => agent.store.messages(s.key).isNotEmpty);
      expect(agent.store.messages(s.key), hasLength(1));
    }
    final groupA = agent.sessions('a').firstWhere((s) => s.kind == 'group');
    expect(agent.store.messages(groupA.key).single.plain, contains('A 群消息'));
    final privateA = agent.sessions('a').firstWhere((s) => s.kind == 'private');
    await agent.send(privateA.key, '[CQ:at,qq=all] 普通文本');
    expect(a.sent.single['action'], 'send_private_msg');
    expect(a.sent.single['user_id'], 20002);
    expect((a.sent.single['message'] as List).single['type'], 'text');
    expect(b.sent, isEmpty);
  });
  test('事件去重、错误账号和机器人自身消息不会触发 AI', () async {
    final t = await connect('a', '10001');
    t.receive(self: '99999', content: '错误账号');
    t.receive(user: '10001', content: '自己发送');
    t.receive(id: '2', content: '合法消息');
    t.receive(id: '2', content: '合法消息');
    await eventually(() => t.sent.length == 1);
    expect(model.requests, hasLength(1));
    expect(agent.sessions(), hasLength(1));
    expect(
      agent.store
          .messages(agent.sessions().single.key)
          .where((m) => m.id == 'ob:2'),
      hasLength(1),
    );
    expect(jsonEncode(model.requests), isNot(contains('fixture-api-key')));
  });
  test('群 @、命令边界、白名单和关闭 AI 的命令插件生效', () async {
    final e = agent.extensions.firstWhere((e) => e.id == 'hello');
    await agent.saveExtension(AgentExtension(e.manifest, enabled: true));
    final t = await connect(
      'a',
      '10001',
      ai: false,
      trigger: 'command',
      plugins: ['hello'],
      groups: ['20002'],
    );
    t.receive(id: '1', content: '/hello2', mention: false);
    t.receive(id: '2', content: '/hello', mention: false, peer: '77777');
    t.receive(id: '3', content: '/hello', mention: false);
    await eventually(() => t.sent.isNotEmpty);
    expect(model.requests, isEmpty);
    expect(t.sent, hasLength(1));
    expect(jsonEncode(t.sent), contains('小明'));
    final a = await connect('b', '10002');
    a.receive(id: '1', mention: false);
    a.receive(id: '2', mention: true);
    await eventually(() => a.sent.isNotEmpty);
    expect(a.sent, hasLength(1));
  });
  test('编辑连接 / 停止 / 暂停 / 清除上下文取消进行中的回复', () async {
    for (final operation in ['disconnect', 'pause', 'context', 'preset']) {
      final wait = Completer<Json>();
      model.handler = (_, _) => wait.future;
      final t = await connect('a', '10001');
      final before = model.requests.length;
      t.receive(id: operation);
      await eventually(() => model.requests.length > before);
      final s = agent.sessions('a').single;
      if (operation == 'disconnect') await agent.disconnect('a');
      if (operation == 'pause') {
        s.paused = true;
        await agent.configureSession(s);
      }
      if (operation == 'context') await agent.clearContext(s.key);
      if (operation == 'preset') {
        await agent.savePreset(
          AgentPreset(
            id: 'assistant',
            name: '新预设',
            prompt: 'changed',
            providerId: 'model',
          ),
        );
      }
      wait.complete(answer('不应再发送'));
      await eventually(() => agent.busySessions.isEmpty);
      expect(t.sent, isEmpty, reason: operation);
      s.paused = false;
      await agent.configureSession(s);
    }
  });
  test('上下文、长期备注和所选预设只属于当前会话', () async {
    final a = await connect('a', '10001'), b = await connect('b', '10002');
    final s = await agent.openSession('a', 'group', '20002');
    s.memory = '只有 A 能使用的备注';
    await agent.configureSession(s);
    a.receive(content: 'A 的私有历史');
    await eventually(() => a.sent.isNotEmpty);
    b.receive(content: 'B 的问题');
    await eventually(() => b.sent.isNotEmpty);
    final first = jsonEncode(model.requests.first),
        last = jsonEncode(model.requests.last);
    expect(first, contains('只有 A'));
    expect(last, isNot(contains('只有 A')));
    expect(last, isNot(contains('A 的私有历史')));
    await agent.clearContext(s.key);
    a.receive(id: 'next', content: '新问题');
    await eventually(() => a.sent.length == 2);
    expect(jsonEncode(model.requests.last), isNot(contains('A 的私有历史')));
    expect(
      agent.store.messages(s.key).any((m) => m.plain.contains('A 的私有历史')),
      isTrue,
    );
  });
  test('Skill 仅在启用且预设选择时传给模型，工具执行回填后才发送', () async {
    final clock = agent.extensions.firstWhere((e) => e.id == 'clock');
    await agent.saveExtension(AgentExtension(clock.manifest, enabled: true));
    await agent.savePreset(
      AgentPreset(
        id: 'assistant',
        name: '测试',
        prompt: '测试',
        providerId: 'model',
        skillIds: ['clock'],
      ),
    );
    model.handler = (n, request) async => n == 1
        ? {
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': [
                    {
                      'id': 'call1',
                      'type': 'function',
                      'function': {'name': 'current_time', 'arguments': '{}'},
                    },
                  ],
                },
              },
            ],
          }
        : answer('查询完成');
    final t = await connect('a', '10001');
    t.receive();
    await eventually(() => t.sent.isNotEmpty);
    expect(model.requests.first['tools'], hasLength(1));
    expect((model.requests.last['messages'] as List).last['role'], 'tool');
    expect(t.sent, hasLength(1));
    expect(jsonEncode(agent.logs), contains('current_time'));
  });
  test('扩展导入不会自动启用或导入秘密，原 JS 清单不静默接受', () {
    final e = AgentExtension.parse(
      jsonEncode({
        ...agentExamples().first.manifest,
        'enabled': true,
        'secrets': {'KEY': 'bad'},
      }),
    );
    expect(e.enabled, isFalse);
    expect(e.secrets, isEmpty);
    expect(e.manifest.containsKey('secrets'), isFalse);
    expect(
      () => AgentExtension.parse('{"apiVersion":1,"id":"legacy"}'),
      throwsA(isA<AgentException>()),
    );
    final md = AgentExtension.parse(
      '---\nid: writer\nname: 写作\ndescription: 写作助手\n---\n帮忙润色。',
      filename: 'SKILL.md',
    );
    expect(md.kind, 'skill');
    expect(md.prompt, '帮忙润色。');
  });
  test('HTTP 权限与工具参数拒绝动态 URL、未知参数和非法来源', () {
    expect(
      () => AgentExtension.parse(
        jsonEncode({
          'schema': 1,
          'id': 'unsafe',
          'name': 'x',
          'kind': 'plugin',
          'commands': [
            {
              'prefix': '/x',
              'handler': {'type': 'http', 'url': 'https://example.com/private'},
            },
          ],
        }),
      ),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => validateArguments(
        {'extra': 'x'},
        {'type': 'object', 'properties': <String, dynamic>{}},
      ),
      throwsA(isA<AgentException>()),
    );
  });
  test('Agent 脚本单独运行、传入上下文和返回状态，不可访问文件系统', () async {
    final runner = AgentScripts();
    addTearDown(runner.close);
    final sample = agentExamples().firstWhere((e) => e.id == 'script_echo');
    final result = await runner.run(
      text(object(sample.commands.single['handler'])['source']),
      {
        'args': {'text': '隔离执行'},
      },
    );
    expect(result['text'], '隔离执行');
    await expectLater(
      runner.run(
        'fun run(input) { return File("/secret").readAsString() }',
        {},
      ),
      throwsA(isA<AgentException>()),
    );
  });
  test('使用真实独立 Hive 文件，已有官方消息和配置保持不变', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqm-agent-storage-test-',
    );
    final hive = Hive;
    hive.init(directory.path);
    final official = await hive.openBox<String>('messages');
    await official.put('official:original', 'original-body');
    final store = AgentStore();
    try {
      await store.open();
      await store.put('connection:onebot', {'id': 'onebot'});
      expect(official.keys.toList(), ['official:original']);
      expect(official.get('official:original'), 'original-body');
      expect(File('${directory.path}/qqm_agent_v1.hive').existsSync(), isTrue);
    } finally {
      await store.close();
      await official.close();
      await directory.delete(recursive: true);
    }
  });
  test('HTTP 模型接口发送及响应实际可用，拒绝重定向并隐藏响应密钥', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = AgentHttp();
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    Json? requestBody;
    String? authorization;
    server.listen((r) async {
      if (r.uri.path == '/redirect') {
        r.response.statusCode = 302;
        r.response.headers.set('location', '/target');
      } else if (r.uri.path == '/error') {
        r.response.statusCode = 401;
        r.response.write('fixture-secret-do-not-show');
      } else {
        authorization = r.headers.value('authorization');
        requestBody = object(jsonDecode(await utf8.decoder.bind(r).join()));
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(answer('真实 HTTP 模拟响应')));
      }
      await r.response.close();
    });
    final provider = AgentProvider(
      id: 'http',
      name: 'http',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'local',
      apiKey: 'fixture-key',
    );
    final response = await CompatibleAgentModel(
      client,
    ).complete(provider, {'model': 'local', 'messages': []}, CancelToken());
    expect(authorization, 'Bearer fixture-key');
    expect(requestBody!['model'], 'local');
    expect(jsonEncode(response), contains('真实 HTTP'));
    await expectLater(
      client.request(Uri.parse('http://127.0.0.1:${server.port}/redirect')),
      throwsA(isA<AgentException>()),
    );
    try {
      await client.request(Uri.parse('http://127.0.0.1:${server.port}/error'));
      fail('must fail');
    } on AgentException catch (e) {
      expect(e.message, contains('401'));
      expect(e.message, isNot(contains('fixture-secret')));
    }
  });
}
