import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/reply_format.dart';
import 'package:qq_bot_manager/agent/store.dart';

import 'agent_core_test.dart' as core;

const _first = '真的会。你们说什么我就学什么，学得多了听起来就像本群原住民。';
const _second = '不过有一点不会：我不会替人做决定，也不会假装自己是人。你刚说“不要啊”，我记下了；我还在，只是把说话方式调得更贴近你们了。';
const _answer = '$_first\n\n$_second';

void main() {
  test('普通两段回复按空行分成两个气泡，关闭分条时仍是一条', () {
    expect(agentReplyMessages(_answer, enabled: true), [_first, _second]);
    expect(agentReplyMessages(_answer, enabled: false), [_answer]);
    expect(agentReplyMessages('第一句话。第二句话。', enabled: true), ['第一句话。第二句话。']);
    expect(agentReplyMessages('第一行\n第二行', enabled: true), ['第一行\n第二行']);
    expect(
      agentReplyMessages(
        ' \r\n$_first\r\n \t\r\n\r\n$_second\r\n',
        enabled: true,
      ),
      [_first, _second],
    );
  });

  test('单元素JSON中的普通段落也可分条，多元素JSON沿用明确边界', () {
    expect(
      agentReplyMessages(
        jsonEncode({
          'messages': [_answer],
        }),
        enabled: true,
      ),
      [_first, _second],
    );
    expect(
      agentReplyMessages(
        jsonEncode({
          'messages': [_answer, '第三条'],
        }),
        enabled: true,
      ),
      [_answer, '第三条'],
    );
    expect(
      agentReplyMessages(
        '```json\n${jsonEncode({
          'messages': [_answer],
        })}\n```',
        enabled: true,
      ),
      [_first, _second],
    );
  });

  test('分条上限与被动回复额度不足时合并尾部，不丢内容', () {
    const answer = '一\n\n二\n\n三\n\n四';
    expect(agentReplyMessages(answer, enabled: true, maxParts: 2), [
      '一',
      '二\n\n三\n\n四',
    ]);
    expect(agentReplyMessages(answer, enabled: true, maxParts: 1), [answer]);
    expect(
      agentReplyMessages(
        '${'a' * 7000}\n\n${'b' * 7000}',
        enabled: true,
      ).map((p) => p.length).reduce((a, b) => a + b),
      12000,
    );
  });

  test('代码、列表、表格与其他复杂排版不在内部空行处拆开', () {
    const cases = [
      '示例：\n\n```dart\nvoid main() {\n\n  print("hello");\n}\n```\n\n结束。',
      '````markdown\n```js\nhello\n\nworld\n```\n````',
      '示例：\n\n~~~js\nhello\n\nworld\n~~~',
      '- 第一项\n\n- 第二项',
      '1. 第一项\n\n2. 第二项',
      '# 标题\n\n正文',
      '名称 | 说明\n--- | ---\n甲 | 乙\n\n下一段',
      '> 第一段\n>\n> 第二段\n\n引用说明',
      '示例\n\n    first\n\n    second',
      '\$\$\nx = y\n\n+ z\n\$\$\n\n说明',
      '<div>第一段\n\n第二段</div>',
      '[ref]: https://example.com\n\n正文',
      '{\n  "example": "value",\n\n  "other": true\n}',
    ];
    for (final source in cases) {
      expect(agentReplyMessages(source, enabled: true), [
        source,
      ], reason: source);
      expect(
        agentReplyMessages(
          jsonEncode({
            'messages': [source],
          }),
          enabled: true,
        ),
        [source],
        reason: source,
      );
    }
    expect(agentReplyMessages('**你好**，`x` 是变量。\n\n我们继续。', enabled: true), [
      '**你好**，`x` 是变量。',
      '我们继续。',
    ]);
  });

  test('空内容、残缺分条JSON仍拦截，不把协议包装发送到QQ', () {
    for (final source in [
      '',
      ' \n\n ',
      '{"messages":[]}',
      '{"messages":[" "]}',
      '{"messages":[]}extra',
      '{"messages":[1]}',
    ]) {
      expect(
        () => agentReplyMessages(source, enabled: true),
        throwsA(isA<AgentException>()),
      );
    }
  });

  for (final protocol in ['onebot', 'qqbot']) {
    for (final enabled in [false, true]) {
      test('$protocol 普通段落实际按分条开关发送，只有一次模型调用', () async {
        final model = core.FakeAgentModel()
          ..handler = (_, _) async => core.answer(_answer);
        late core.FakeAgentTransport transport;
        final agent = AgentController(
          store: AgentStore.memory(),
          model: model,
          transportFactory: (c) => transport = core.FakeAgentTransport(c),
        );
        addTearDown(() async {
          await agent.shutdown();
          agent.dispose();
        });
        await agent.initialize();
        await agent.saveProvider(
          AgentProvider(
            id: 'm',
            name: '模型',
            baseUrl: 'https://model.example/v1',
            model: 'fixture',
          ),
        );
        await agent.savePreset(
          AgentPreset(
            id: 'p',
            name: '预设',
            prompt: '自然回复',
            providerId: 'm',
            multiMessageReply: enabled,
            replyIntervalMs: 0,
          ),
        );
        await agent.saveConnection(
          AgentConnection(
            id: 'c',
            name: '机器人',
            selfId: '10001',
            protocol: protocol,
            clientSecret: protocol == 'qqbot' ? 'fixture-only' : '',
            presetId: 'p',
          ),
        );
        await agent.connect('c');
        final session = await agent.openSession('c', 'group', '20002');
        await agent.store.append(
          AgentMessage(
            id: 'trigger',
            sessionKey: session.key,
            senderId: '30003',
            senderName: '群友',
            segments: [textSegment('说两句')],
          ),
        );
        await agent.regenerate(session.key);
        await core.eventually(
          () => transport.sent.isNotEmpty && agent.busySessions.isEmpty,
        );
        expect(model.requests.length, 1);
        expect(transport.sent.length, enabled ? 2 : 1);
        expect(
          agent.store
              .messages(session.key)
              .where((m) => m.outgoing)
              .map((m) => m.plain),
          enabled ? [_first, _second] : [_answer],
        );
      });
    }
  }
}
