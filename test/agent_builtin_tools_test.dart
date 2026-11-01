import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/agent/ai.dart';
import 'package:qq_bot_manager/agent/builtin_tools.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/holidays.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/web.dart';
import 'agent_core_test.dart' as fixtures;
import 'agent_js_packages_test.dart' as js;

class BuiltinHttp extends AgentHttp {
  final requests = <Uri>[];
  final png = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 32, height: 32)..clear(img.ColorRgb8(30, 100, 220)),
    ),
  );
  @override
  Future<({Uint8List bytes, int status, Map<String, String> headers})>
  fetchBytes(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    CancelToken? cancel,
    int maxBytes = 12 * 1024 * 1024,
    int timeoutSeconds = 15,
  }) async {
    requests.add(uri);
    expect(uri.scheme, 'https');
    expect(
      headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
    );
    return (bytes: png, status: 200, headers: {'content-type': 'image/png'});
  }
}

class BuiltinTransport extends fixtures.FakeAgentTransport {
  final calls = <Json>[];
  bool failSecond = false, noReceipt = false;
  BuiltinTransport(super.config);
  @override
  Future<dynamic> call(String action, [Json params = const {}]) async {
    calls.add({'action': action, ...params});
    if (action == 'get_group_member_info' || action == 'get_stranger_info') {
      return {
        'nickname': '真实昵称',
        'user_id': params['user_id'],
        'role': 'member',
      };
    }
    if (action == 'get_group_info') {
      return {'group_name': '真实群名', 'member_count': 42};
    }
    if (action == 'get_image') {
      return {'url': 'http://gchat.qpic.cn/fixture.png'};
    }
    if (action.startsWith('send_') &&
        (noReceipt || (failSecond && sent.length == 1))) {
      throw const AgentException('fixture 未取得回执');
    }
    return super.call(action, params);
  }

  @override
  Future<Json> loadOfficialProfile(
    String kind,
    String peerId, {
    String memberId = '',
    String lookupId = '',
    bool force = false,
  }) async => {
    'name': kind == 'group' ? '官机真实群名' : '官机真实昵称',
    if (kind == 'group') 'member_count': 35,
  };
}

class ReceiptRaceStore extends AgentStore {
  String? receiveAfterSending;
  int received = 0;
  ReceiptRaceStore() : super.memory();

  @override
  Future<void> put(String key, Json value) async {
    await super.put(key, value);
    final session = receiveAfterSending;
    if (session == null || key != 'session:$session') return;
    receiveAfterSending = null;
    await append(
      AgentMessage(
        id: 'ob:incoming-${++received}',
        sessionKey: session,
        senderId: '30003',
        senderName: '提问者',
        segments: [textSegment('发送回执期间的新消息')],
      ),
    );
  }
}

void main() {
  late AgentController agent;
  late BuiltinHttp http;
  late fixtures.FakeAgentModel model;
  final transports = <String, BuiltinTransport>{};
  AgentPreset preset([Json extra = const {}]) => AgentPreset.fromJson({
    'id': 'p',
    'name': '测试预设',
    'prompt': '使用真实工具回复',
    ...extra,
  });
  setUp(() async {
    http = BuiltinHttp();
    model = fixtures.FakeAgentModel();
    transports.clear();
    agent = AgentController(
      store: ReceiptRaceStore(),
      http: http,
      model: model,
      transportFactory: (c) => transports[c.id] = BuiltinTransport(c),
    );
    await agent.initialize();
  });
  tearDown(() async {
    await agent.shutdown();
    agent.dispose();
  });
  Future<AgentSession> chat({
    String id = 'a',
    bool official = false,
    String peer = '20002',
  }) async {
    await agent.saveConnection(
      AgentConnection(
        id: id,
        name: '测试机器人',
        selfId: official
            ? '1904104647'
            : id == 'b'
            ? '10002'
            : '10001',
        protocol: official ? 'qqbot' : 'onebot',
        clientSecret: official ? 'fixture-only' : '',
        aiEnabled: false,
      ),
    );
    await agent.connect(id);
    return agent.openSession(id, 'group', peer, name: '当前群');
  }

  Future<AgentMessage> user(
    AgentSession s,
    String text, {
    String id = 'user-message',
    String sender = '30003',
    List<Json> extra = const [],
  }) async {
    final message = AgentMessage(
      id: 'ob:$id',
      sessionKey: s.key,
      senderId: sender,
      senderName: '提问者',
      segments: [textSegment(text), ...extra],
    );
    await agent.store.append(message);
    return message;
  }

  Future<Json> call(
    AgentSession s,
    AgentMessage m,
    String name, [
    Json args = const {},
    AgentPreset? p,
  ]) => agent.executeBuiltinTool(s.key, name, args, trigger: m, preset: p);
  Json data(Json result) => object(jsonDecode(text(result['text'])));

  test('旧预设自动获得工具，开关/视觉/协议/跨会话可用性真实过滤', () {
    final p = preset();
    expect(p.builtinToolsEnabled, true);
    expect(p.maxToolCalls, 12);
    expect(AgentPreset.fromJson(p.toJson()).toJson(), p.toJson());
    List<String> names(
      AgentPreset settings, {
      bool official = false,
      bool vision = false,
    }) => agentBuiltinDefinitions(
      preset: settings,
      official: official,
      vision: vision,
    ).map((tool) => text(tool['name'])).toList();
    expect(
      names(p),
      containsAll([
        'send_message',
        'get_recent_messages',
        'memory_append',
        'set_reminder',
        'send_poke',
      ]),
    );
    expect(names(p), isNot(contains('get_user_avatar')));
    expect(names(p, official: true, vision: true), contains('get_user_avatar'));
    expect(
      names(p, official: true, vision: true),
      isNot(contains('send_poke')),
    );
    expect(names(p), isNot(contains('send_to')));
    expect(names(preset({'builtinToolsEnabled': false})), isEmpty);
    expect(
      names(
        preset({
          'disabledBuiltinTools': ['memory_append'],
        }),
      ),
      isNot(contains('memory_append')),
    );
    expect(
      () => preset({'maxToolCalls': 33}).validate(),
      throwsA(isA<AgentException>()),
    );
  });

  for (final official in [false, true]) {
    test('${official ? "QQBot" : "OneBot"} 无图片附件时真实取得用户头像并交给视觉模型', () async {
      final s = await chat(official: official),
          m = await user(
            await Future.value(agent.sessions().single),
            '评价一下我的头像',
          );
      final p = preset();
      await agent.ai.reply(
        provider: AgentProvider(
          id: 'vision',
          name: '看图模型',
          baseUrl: 'https://model.example/v1',
          model: 'v',
          vision: true,
        ),
        preset: p,
        session: s,
        history: [m],
        triggerMessage: m,
        skills: [],
        builtinTools: agentBuiltinDefinitions(
          preset: p,
          official: official,
          vision: true,
        ),
        onBuiltinTool: (name, args) => call(s, m, name, args, p),
        turn: AgentTurn(() => true),
        onUsage: (_, _) {},
        onTool: (_) {},
      );
      expect(http.requests, hasLength(1));
      expect(
        http.requests.single.host,
        official ? 'q.qlogo.cn' : 'q1.qlogo.cn',
      );
      if (official) {
        expect(http.requests.single.path, '/qqapp/1904104647/30003/640');
      }
      final messages = model.requests.single['messages'] as List;
      expect(jsonEncode(messages), contains('data:image/jpeg;base64,'));
      expect(transports[s.connectionId]!.sent, isEmpty);
    });
  }

  test('当前消息请求的头像通过转述模型提供给纯文本模型', () async {
    final s = await chat(),
        m = await user(await Future.value(agent.sessions().single), '我的头像怎么样');
    model.handler = (_, request) async =>
        fixtures.answer(request['model'] == 'caption' ? '蓝色的方形图案' : '评价结果');
    final p = preset();
    await agent.ai.reply(
      provider: AgentProvider(
        id: 'main',
        name: '文字',
        baseUrl: 'https://model.example/v1',
        model: 'main',
      ),
      imageDescriptionProvider: AgentProvider(
        id: 'caption',
        name: '转述',
        baseUrl: 'https://vision.example/v1',
        model: 'caption',
        vision: true,
      ),
      preset: p,
      session: s,
      history: [m],
      triggerMessage: m,
      skills: [],
      builtinTools: agentBuiltinDefinitions(
        preset: p,
        official: false,
        vision: true,
      ),
      onBuiltinTool: (name, args) => call(s, m, name, args),
      turn: AgentTurn(() => true),
      onUsage: (_, _) {},
      onTool: (_) {},
    );
    final last = jsonEncode(model.requests.last);
    expect(last, contains('蓝色的方形图案'));
    expect(last, isNot(contains('image_url')));
  });

  test('查询历史/搜索/用户资料只在当前机器人和会话', () async {
    final a = await chat(), b = await chat(id: 'b');
    final m = await user(a, '今天学习Dart');
    await user(b, '另一个机器人的私密话');
    expect(
      text((await call(a, m, 'get_recent_messages'))['text']),
      isNot(contains('私密')),
    );
    expect(
      data(await call(a, m, 'search_messages', {'query': 'Dart'}))['messages'],
      hasLength(1),
    );
    final info = data(await call(a, m, 'get_user_info'));
    expect(info['nickname'], '真实昵称');
    expect(transports['a']!.calls.last['action'], 'get_group_member_info');
    expect(data(await call(a, m, 'get_group_info'))['member_count'], 42);
    await expectLater(
      call(a, m, 'get_user_avatar', {'userId': '99999'}),
      throwsA(isA<AgentException>()),
    );
    await expectLater(
      call(a, m, 'get_recent_messages', {'chatKey': b.key}),
      throwsA(isA<AgentException>()),
    );
  });

  test('官机资料和群人数取自真实适配器，不把OpenID变成QQ号', () async {
    final s = await chat(official: true),
        m = await user(await Future.value(agent.sessions().single), '看看资料');
    final info = data(await call(s, m, 'get_user_info'));
    expect(info['name'], '官机真实昵称');
    expect(info['id'], '30003');
    expect(info['avatarUrl'], contains('/1904104647/30003/'));
    expect(data(await call(s, m, 'get_group_info'))['member_count'], 35);
  });

  test('记忆按会话保存，不能伪造删除别人的记录', () async {
    final s = await chat(),
        m = await user(await Future.value(agent.sessions().single), '记住我喜欢音乐');
    final row = data(await call(s, m, 'memory_append', {'content': '喜欢音乐'}));
    expect(data(await call(s, m, 'memory_query'))['items'], hasLength(1));
    expect(
      agent.builtinMemoryContext(agent.connection('a')!, s),
      contains('喜欢音乐'),
    );
    final other = await user(s, '删除', sender: '40004', id: 'other');
    await expectLater(
      call(s, other, 'memory_remove', {'id': row['id']}),
      throwsA(isA<AgentException>()),
    );
    await call(s, m, 'memory_remove', {'id': row['id']});
    expect(data(await call(s, m, 'memory_query'))['items'], isEmpty);
  });

  test('提醒到期发送有回执，仅执行一次；失败不反复重试', () async {
    final s = await chat(),
        m = await user(await Future.value(agent.sessions().single), '两秒后提醒我喝水');
    final row = data(
      await call(s, m, 'set_reminder', {'inSeconds': 2, 'text': '喝水'}),
    );
    final due = DateTime.parse(text(row['at'])).add(const Duration(seconds: 1));
    await agent.processReminders(now: due);
    await agent.processReminders(now: due);
    expect(transports['a']!.sent, hasLength(1));
    expect(agent.store.get('agent-reminder:${row['id']}')?['status'], 'sent');
    final bad = data(
      await call(s, m, 'set_reminder', {'inSeconds': 2, 'text': '测试失败'}),
    );
    transports['a']!.noReceipt = true;
    await agent.processReminders(
      now: DateTime.parse(text(bad['at'])).add(const Duration(seconds: 1)),
    );
    await agent.processReminders(now: due.add(const Duration(minutes: 1)));
    expect(agent.store.get('agent-reminder:${bad['id']}')?['status'], 'failed');
    expect(transports['a']!.sent, hasLength(1));
  });

  test('大量未来提醒不会阻塞后加入的到期提醒', () async {
    final s = await chat(), m = await user(agent.sessions().single, '提醒我');
    for (var i = 0; i < 100; i++) {
      await agent.store.put('agent-reminder:later-$i', {
        'id': 'later-$i',
        'connectionId': 'a',
        'selfId': s.selfId,
        'chatKey': s.key,
        'userId': '40004',
        'text': '明天的提醒',
        'at': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
        'status': 'pending',
      });
    }
    final row = data(
      await call(s, m, 'set_reminder', {'inSeconds': 2, 'text': '现在执行'}),
    );
    await agent.processReminders(
      now: DateTime.parse(text(row['at'])).add(const Duration(seconds: 1)),
    );
    expect(transports['a']!.sent, hasLength(1));
    expect(agent.store.get('agent-reminder:${row['id']}')?['status'], 'sent');
    expect(agent.store.get('agent-reminder:later-0')?['status'], 'pending');
  });

  test('只能取消本人提醒，改换账号后不执行旧提醒', () async {
    final s = await chat(),
        m = await user(await Future.value(agent.sessions().single), '提醒');
    final row = data(
      await call(s, m, 'set_reminder', {'inSeconds': 2, 'text': '喝水'}),
    );
    final other = await user(s, '取消', sender: '40004', id: 'other');
    await expectLater(
      call(s, other, 'cancel_reminder', {'id': row['id']}),
      throwsA(isA<AgentException>()),
    );
    await call(s, m, 'cancel_reminder', {'id': row['id']});
    await agent.processReminders(
      now: DateTime.now().add(const Duration(seconds: 10)),
    );
    expect(transports['a']!.sent, isEmpty);
  });

  test('表情库保存真实图片，预览与发送成功且跨机器人隔离', () async {
    final s = await chat(), b = await chat(id: 'b');
    final m = await user(
      s,
      '收藏这张',
      extra: [
        {
          'type': 'image',
          'data': {'file': 'base64://${base64Encode(http.png)}'},
        },
      ],
    );
    final row = data(await call(s, m, 'collect_sticker', {'note': '蓝色'}));
    expect(data(await call(s, m, 'list_stickers'))['items'], hasLength(1));
    final preview = await call(s, m, 'get_sticker_image', {'id': row['id']});
    expect(preview['images'], hasLength(1));
    expect((await call(s, m, 'send_sticker', {'id': row['id']}))['sent'], true);
    final other = await user(b, '列出表情');
    expect(data(await call(b, other, 'list_stickers'))['items'], isEmpty);
  });

  test('分条发送支持真实@和引用，部分失败不丢弃已确认回执', () async {
    final s = await chat(),
        m = await user(await Future.value(agent.sessions().single), '你好');
    transports['a']!.failSecond = true;
    final result = await call(s, m, 'send_message', {
      'messages': ['你好', '继续'],
      'atUserId': m.senderId,
      'replyToMessageId': m.id,
    });
    expect(result['sent'], true);
    expect(data(result)['sent'], 1);
    expect(result['isError'], true);
    expect(transports['a']!.sent, hasLength(1));
    final segments = parseSegments(transports['a']!.sent.single['message']);
    expect(segments.map((seg) => seg['type']), ['at', 'reply', 'text']);
  });

  test('并发新消息不会替代文字和图片的实际发送回执', () async {
    final s = await chat(), m = await user(agent.sessions().single, '你好');
    final store = agent.store as ReceiptRaceStore;
    store.receiveAfterSending = s.key;
    final sent = await call(s, m, 'send_message', {
      'messages': ['确认的回复'],
    });
    expect(data(sent)['messageIds'], ['ob:sent-1']);
    expect(agent.store.messages(s.key).last.id, 'ob:incoming-1');
    store.receiveAfterSending = s.key;
    final image = await agent.sendImage(s.key, http.png);
    expect(image['message_id'], 'ob:sent-2');
    expect(agent.store.messages(s.key).last.id, 'ob:incoming-2');
  });

  test('跨会话默认关闭，开启后仍不能跨机器人或用引用授权', () async {
    final s = await chat(), b = await chat(id: 'b');
    final m = await user(s, '请转告另一个群你好');
    await expectLater(
      call(s, m, 'send_to', {'chatKey': b.key, 'text': '你好'}),
      throwsA(isA<AgentException>()),
    );
    await expectLater(
      call(s, m, 'send_to', {
        'chatKey': b.key,
        'text': '你好',
      }, preset({'crossChatSendEnabled': true})),
      throwsA(isA<AgentException>()),
    );
    expect(transports['b']!.sent, isEmpty);
  });

  test('OneBot图片只有不透明file标识时向当前协议查询，不读取本地文件', () async {
    final s = await chat();
    final m = await user(
      s,
      '看看图片',
      extra: [
        {
          'type': 'image',
          'data': {'file': 'QQ-image-file-id.image'},
        },
      ],
    );
    final result = await call(s, m, 'get_message_images');
    expect(
      text(object((result['images'] as List).single)['data']),
      contains('https://gchat.qpic.cn/fixture.png'),
    );
    expect(
      transports['a']!.calls.where((row) => row['action'] == 'get_image'),
      hasLength(1),
    );
    expect(http.requests, isEmpty);
  });
  test('收藏OneBot图片兼容QQ旧HTTP链接和文件标识，关闭上下文不读取转发', () async {
    final s = await chat();
    for (final file in ['http://gchat.qpic.cn/fixture.png', 'fixture.image']) {
      final m = await user(
        s,
        '收藏图片',
        id: file,
        extra: [
          {
            'type': 'image',
            'data': {'file': file},
          },
          {
            'type': 'forward',
            'data': {'id': 'not-authorized-to-read'},
          },
        ],
      );
      final saved = data(
        await call(
          s,
          m,
          'collect_sticker',
          const {},
          preset({'readMessageContext': false}),
        ),
      );
      expect(agent.builtinStickerBytes('a', text(saved['id'])), http.png);
    }
    expect(http.requests, hasLength(2));
    expect(http.requests.every((uri) => uri.scheme == 'https'), true);
    expect(
      transports['a']!.calls.where((row) => row['action'] == 'get_forward_msg'),
      isEmpty,
    );
  });
  test('资料页面缓存不因普通日志改变而重复读取，删除只作用于当前机器人', () async {
    final s = await chat();
    final m = await user(s, '记录');
    final row = data(await call(s, m, 'memory_append', {'content': '喜欢音乐'}));
    final first = agent.builtinData('a');
    expect(identical(first, agent.builtinData('a')), true);
    expect(first['memories'], hasLength(1));
    await chat(id: 'b');
    await expectLater(
      agent.removeBuiltinData('b', 'memories', text(row['id'])),
      throwsA(isA<AgentException>()),
    );
    await agent.removeBuiltinData('a', 'memories', text(row['id']));
    expect(agent.builtinData('a')['memories'], isEmpty);
  });
  test('原包模块可代理当前模型、查询成员及URL发图，不接触API密钥', () async {
    final extension = AgentExtension.fromPackage(
      js.bundle(
        source: r'''
import { chatCompletion } from '../../../src/llm.js';
export function setup(api) {
  api.registerTool({id:'probe',description:'集成测试',parameters:{type:'object',properties:{},additionalProperties:false},execute:async ctx=>{
    const r=await chatCompletion({messages:[{role:'user',content:'plugin-model-probe'}]});
    const info=await ctx.qq.getUserInfo();
    const members=ctx.store.activeMembers(ctx.chatKey,10);
    await ctx.sender.sendImage(ctx.chatKey,{url:'https://images.example/fixture.png'});
    return {content:JSON.stringify({reply:r.choices[0].message.content,name:info.nickname,members:members.length})};
  }});
}
''',
      ),
    );
    await agent.saveExtension(extension.copyWith(enabled: true));
    await agent.saveProvider(
      AgentProvider(
        id: 'model',
        name: '模型',
        baseUrl: 'https://model.example/v1',
        apiKey: 'fixture-secret-never-in-package',
        model: 'test',
      ),
    );
    await agent.savePreset(
      preset({
        'providerId': 'model',
        'skillIds': ['fixture'],
      }),
    );
    await agent.saveConnection(
      AgentConnection(
        id: 'a',
        name: '测试',
        selfId: '10001',
        aiEnabled: true,
        presetId: 'p',
        cooldownSeconds: 0,
      ),
    );
    await agent.connect('a');
    model.handler = (round, request) async {
      if (jsonEncode(request['messages']).contains('plugin-model-probe')) {
        return fixtures.answer('宿主代理回答');
      }
      if (round == 1) {
        return {
          'choices': [
            {
              'message': {
                'tool_calls': [
                  {
                    'id': 'probe',
                    'type': 'function',
                    'function': {'name': 'fixture__probe', 'arguments': '{}'},
                  },
                ],
              },
            },
          ],
        };
      }
      return fixtures.answer('完成');
    };
    transports['a']!.receive(content: '测试扩展');
    await fixtures.eventually(
      () => agent.busySessions.isEmpty && transports['a']!.sent.length == 2,
    );
    expect(http.requests.single.host, 'images.example');
    expect(
      jsonEncode(model.requests),
      isNot(contains('fixture-secret-never-in-package')),
    );
    expect(jsonEncode(model.requests.last), contains('宿主代理回答'));
  });

  test('Bing图搜与网页图片解析只返回真实HTTPS条目，节日表不假装调休表', () {
    final rows = parseBingImages(
      '<a m="{&quot;murl&quot;:&quot;https://img.example/a.png&quot;,&quot;t&quot;:&quot;图片&quot;}"></a><a m="{&quot;murl&quot;:&quot;javascript:bad()&quot;}"></a>',
    );
    expect(rows, hasLength(1));
    expect(rows.single['url'], 'https://img.example/a.png');
    expect(
      parseWebImages(
        '<img src="/a.png"><img src="javascript:bad()">',
        'https://example.com/page',
      ),
      hasLength(1),
    );
    expect(
      (agentHolidays('2026-02-17', 0)['holidays'] as List).single['name'],
      '春节',
    );
    expect(agentHolidays('2026-10-25', 7)['officialLeaveSchedule'], false);
  });
}
