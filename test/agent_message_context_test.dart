import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/message_context.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'agent_core_test.dart' as core;

class ForwardFixture extends core.FakeAgentTransport {
  ForwardFixture(super.config);
  final readIds = <String>[];
  bool fail = false;
  @override
  Future<dynamic> call(String action, [Json params = const {}]) async {
    if (action != 'get_forward_msg') return super.call(action, params);
    readIds.add(text(params['id']));
    if (fail) throw const AgentException('协议端未返回记录');
    return {
      'message': [
        {
          'sender': {'user_id': 30003, 'nickname': '记录作者'},
          'content': [textSegment('记录里的讨论原文')],
        },
        {
          'type': 'node',
          'data': {
            'uin': '30004',
            'name': '另一作者',
            'content': [textSegment('另一条讨论')],
          },
        },
      ],
    };
  }

  void record(String id, {String recordId = 'provided-record'}) =>
      onEvent?.call({
        'post_type': 'message',
        'self_id': config.selfId,
        'message_type': 'group',
        'group_id': '20002',
        'user_id': '30003',
        'message_id': id,
        'sender': {'nickname': '当前提问者'},
        'message': [
          {
            'type': 'at',
            'data': {'qq': config.selfId},
          },
          textSegment('请总结这些记录'),
          {
            'type': 'forward',
            'data': {'id': recordId},
          },
        ],
      });
}

void main() {
  late AgentController agent;
  late core.FakeAgentModel model;
  late ForwardFixture transport;
  setUp(() async {
    model = core.FakeAgentModel();
    agent = AgentController(
      store: AgentStore.memory(),
      model: model,
      transportFactory: (c) => transport = ForwardFixture(c),
    );
    await agent.initialize();
    await agent.saveProvider(
      AgentProvider(
        id: 'model',
        name: '测试模型',
        baseUrl: 'http://127.0.0.1:1/v1',
        model: 'fixture',
      ),
    );
    await agent.savePreset(
      AgentPreset(
        id: 'assistant',
        name: '测试',
        prompt: '结合提问回答',
        providerId: 'model',
        historyMessages: 0,
      ),
    );
    await agent.saveConnection(
      AgentConnection(
        id: 'onebot',
        name: '测试协议端',
        selfId: '10001',
        aiEnabled: true,
        cooldownSeconds: 0,
      ),
    );
    await agent.connect('onebot');
  });
  tearDown(() async {
    await agent.shutdown();
    agent.dispose();
  });
  Future<void> done() => core.eventually(
    () => transport.sent.isNotEmpty && agent.busySessions.isEmpty,
  );

  test('OneBot转发记录按原协议读取后进入AI，历史关闭不影响当前记录', () async {
    transport.record('record');
    await done();
    expect(transport.readIds, ['provided-record']);
    final input = jsonEncode(model.requests.single);
    for (final value in [
      '请总结这些记录',
      '当前提问者',
      '记录作者',
      '另一作者',
      '记录里的讨论原文',
      '另一条讨论',
    ]) {
      expect(input, contains(value));
    }
    expect(jsonEncode(transport.sent), isNot(contains('get_forward_msg')));
  });
  test('关闭读取上下文不请求OneBot记录；协议端失败有日志且不编造内容', () async {
    await agent.savePreset(
      AgentPreset.fromJson({
        ...agent.presets.firstWhere((p) => p.id == 'assistant').toJson(),
        'readMessageContext': false,
      }),
    );
    transport.record('off');
    await done();
    expect(transport.readIds, isEmpty);
    expect(jsonEncode(model.requests.single), isNot(contains('记录里的讨论原文')));
    await agent.savePreset(
      AgentPreset.fromJson({
        ...agent.presets.firstWhere((p) => p.id == 'assistant').toJson(),
        'readMessageContext': true,
      }),
    );
    transport.fail = true;
    transport.record('failed');
    await core.eventually(
      () => transport.sent.length == 2 && agent.busySessions.isEmpty,
    );
    expect(jsonEncode(model.requests.last), contains('聊天记录原文读取失败'));
    expect(jsonEncode(agent.logs), contains('context'));
  });
  test('OneBot本地引用补全文字与作者；不会把引用作者当成当前发送者', () async {
    transport.receive(id: 'original', content: '本地保存的原消息');
    await done();
    transport.onEvent?.call({
      'post_type': 'message',
      'self_id': '10001',
      'message_type': 'group',
      'group_id': '20002',
      'user_id': '30004',
      'message_id': 'quote',
      'sender': {'nickname': '提问用户'},
      'message': [
        {
          'type': 'at',
          'data': {'qq': '10001'},
        },
        {
          'type': 'reply',
          'data': {'id': 'original'},
        },
        textSegment('这段什么意思'),
      ],
    });
    await core.eventually(
      () => transport.sent.length == 2 && agent.busySessions.isEmpty,
    );
    final input = jsonEncode(model.requests.last);
    for (final value in ['本地保存的原消息', '提问用户', '小明', '这段什么意思']) {
      expect(input, contains(value));
    }
    expect(transport.readIds, isEmpty);
  });
  test('本地引用原先的富媒体消息会保留递归内容和图片', () {
    final data = officialBodyData({
      'message_type': 102,
      'msg_elements': [
        {
          'content': '被引用记录里的原文',
          'attachments': [
            {
              'content_type': 'image/png',
              'url': 'https://images.example/context.png',
            },
          ],
        },
      ],
    });
    final original = AgentMessage(
      id: 'ob:old',
      sessionKey: 'current',
      senderId: '20002',
      senderName: '原作者',
      referenceIndex: 'IDX',
      segments: [
        {'type': 'qq_body', 'data': data},
      ],
    );
    final quoted = withLocalQuote(
      [
        {
          'type': 'qq_body',
          'data': officialBodyData({'message_type': 103, 'content': '问题'}),
        },
      ],
      'IDX',
      [original],
      sessionKey: 'current',
    );
    final message = AgentMessage(
      id: 'new',
      sessionKey: 'current',
      senderId: '30003',
      senderName: '提问者',
      segments: quoted,
    );
    expect(message.quotedContext, contains('被引用记录里的原文'));
    expect(message.contextImages, hasLength(1));
    expect(message.inputText, contains('问题'));
  });
}
