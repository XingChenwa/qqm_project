import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/agent/ai.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/images.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/script.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/web.dart';

import 'agent_core_test.dart' as fixtures;

typedef PublicResponse = ({
  Uint8List bytes,
  int status,
  Map<String, String> headers,
});

class FeatureHttp extends AgentHttp {
  final requests = <({Uri uri, Map<String, String> headers, int maxBytes})>[];
  late Future<PublicResponse> Function(Uri) handler;
  @override
  Future<PublicResponse> fetchBytes(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    CancelToken? cancel,
    int maxBytes = 12 * 1024 * 1024,
    int timeoutSeconds = 15,
  }) async {
    requests.add((uri: uri, headers: headers, maxBytes: maxBytes));
    return handler(uri);
  }
}

PublicResponse page(
  String content, {
  int status = 200,
  Map<String, String> headers = const {},
}) => (
  bytes: Uint8List.fromList(utf8.encode(content)),
  status: status,
  headers: {'content-type': 'text/html; charset=utf-8', ...headers},
);

void main() {
  late FeatureHttp http;
  late AgentScripts scripts;
  late fixtures.FakeAgentModel model;
  late AgentAi ai;
  final session = AgentSession(
    connectionId: 'a',
    selfId: '10001',
    kind: 'group',
    peerId: '20002',
    name: '测试群',
  );
  final provider = AgentProvider(
    id: 'text',
    name: '文本',
    baseUrl: 'https://model.example/v1',
    model: 'text-model',
    apiKey: 'fixture-secret',
  );
  final vision = AgentProvider(
    id: 'vision',
    name: '图片',
    baseUrl: 'https://vision.example/v1',
    model: 'vision-model',
    vision: true,
  );
  final fixed = DateTime(2026, 10, 24, 15, 30);
  final png = img.encodePng(img.Image(width: 1800, height: 900));
  AgentPreset preset([Json changes = const {}]) => AgentPreset.fromJson({
    'id': 'assistant',
    'name': '测试预设',
    'prompt': '回答问题',
    'providerId': 'text',
    ...changes,
  });
  AgentMessage message({
    List<Json>? segments,
    DateTime? time,
    AgentSession? chat,
  }) => AgentMessage(
    id: 'trigger',
    sessionKey: (chat ?? session).key,
    senderId: '30003',
    senderName: '小明',
    segments: segments ?? [textSegment('你好')],
    time: time ?? DateTime(2026, 10, 23, 9),
  );
  Json picture([String ref = 'https://images.example/picture.png']) => {
    'type': 'image',
    'data': {'url': ref},
  };
  Future<String> reply({
    AgentPreset? settings,
    AgentProvider? main,
    AgentProvider? caption,
    List<AgentMessage>? history,
    AgentSession? chat,
    AgentTurn? turn,
    void Function(String)? reasoning,
    void Function(String)? notice,
    void Function(int, int)? usage,
    List<AgentExtension> skills = const [],
  }) => ai.reply(
    provider: main ?? provider,
    preset: settings ?? preset(),
    session: chat ?? session,
    history: history ?? [message()],
    skills: skills,
    turn: turn ?? AgentTurn(() => true),
    onUsage: usage ?? (_, _) {},
    onTool: (_) {},
    imageDescriptionProvider: caption,
    onReasoning: reasoning,
    onNotice: notice,
  );

  setUp(() {
    http = FeatureHttp()..handler = (_) async => page('<html>empty</html>');
    scripts = AgentScripts();
    model = fixtures.FakeAgentModel();
    ai = AgentAi(model, AgentExtensions(http, scripts), now: () => fixed);
  });
  tearDown(() {
    scripts.close();
    http.close();
  });

  test('旧配置迁移保留默认，新增六项配置完整往返，尺寸范围校验', () {
    final old = preset();
    expect(old.timeAwareness, true);
    expect(old.imageMaxEdge, 1536);
    expect(old.webSearchEnabled, false);
    expect(old.showReasoning, false);
    final p = preset({
      'imageDescriptionProviderId': 'vision',
      'imageMaxEdge': 768,
      'webSearchEnabled': true,
      'showReasoning': true,
      'timeAwareness': false,
    });
    expect(AgentPreset.fromJson(p.toJson()).toJson(), p.toJson());
    for (final edge in [0, 255, 4097]) {
      expect(
        () => preset({'imageMaxEdge': edge}).validate(),
        throwsA(isA<AgentException>()),
      );
    }
    for (final edge in [256, 1536, 4096]) {
      preset({'imageMaxEdge': edge}).validate();
    }
    final c = AgentConnection(
      id: 'a',
      name: '机器人',
      selfId: '10001',
      extraWakePrefixes: ['小助手', 'hey bot'],
    );
    expect(AgentConnection.fromJson(c.toJson()).extraWakePrefixes, [
      '小助手',
      'hey bot',
    ]);
    expect(
      () => AgentConnection.fromJson({
        ...c.toJson(),
        'extraWakePrefixes': ['\n'],
      }).validate(),
      throwsA(isA<AgentException>()),
    );
  });

  test('额外唤醒前缀按开头和英文单词边界匹配，可包含空格', () {
    expect(matchesAgentWakePrefix(' 小助手你好', '小助手'), true);
    expect(matchesAgentWakePrefix('HEY BOT，你好', 'hey bot'), true);
    expect(matchesAgentWakePrefix('bottle', 'bot'), false);
    expect(matchesAgentWakePrefix('my bot 你好', 'bot'), false);
    expect(matchesAgentWakePrefix('bot你好', 'bot'), true);
    expect(matchesAgentWakePrefix('你好', ''), false);
  });

  test('现实时间同时包含当前日期、时区与消息日期；关闭后不注入', () async {
    await reply();
    var input = jsonEncode(model.requests.single['messages']);
    expect(input, contains(agentTime(fixed)));
    expect(input, contains('2026-10-23'));
    expect(input, contains('星期六'));
    expect(input, contains('UTC'));
    await reply(settings: preset({'timeAwareness': false}));
    input = jsonEncode(model.requests.last['messages']);
    expect(input, isNot(contains('现实世界时间')));
    expect(input, isNot(contains('消息时间')));
    expect(input, isNot(contains('2026-10-23')));
  });

  test('图片等比缩小、白底、首帧 JPEG，不放大且拒绝坏图或巨幅图', () {
    final image = resizeAgentImage(png, 768);
    expect([image.width, image.height], [768, 384]);
    expect(img.decodeJpg(image.bytes)!.width, 768);
    final transparent = img.Image(width: 30, height: 60, numChannels: 4);
    final small = resizeAgentImage(img.encodePng(transparent), 1024);
    expect([small.width, small.height], [30, 60]);
    expect(img.decodeJpg(small.bytes)!.getPixel(0, 0).r, greaterThan(245));
    final gif = resizeAgentImage(img.encodeGif(transparent), 1024);
    expect(img.decodeJpg(gif.bytes), isNotNull);
    expect(
      () => resizeAgentImage(Uint8List.fromList([1, 2, 3]), 1024),
      throwsA(isA<AgentException>()),
    );
    final wide = img.encodePng(img.Image(width: 9000, height: 1));
    expect(() => resizeAgentImage(wide, 1024), throwsA(isA<AgentException>()));
  });

  test('视觉主模型收到实际缩小图片数据而非原 URL，不透传模型密钥', () async {
    http.handler = (_) async =>
        (bytes: png, status: 200, headers: {'content-type': 'image/png'});
    await reply(
      main: vision,
      settings: preset({'imageMaxEdge': 512}),
      history: [
        message(segments: [picture()]),
      ],
    );
    final messages = (model.requests.single['messages'] as List).map(object);
    final parts = messages.last['content'] as List;
    final url = text(object(object(parts.last)['image_url'])['url']);
    expect(url, startsWith('data:image/jpeg;base64,'));
    expect(img.decodeJpg(base64Decode(url.split(',').last))!.width, 512);
    expect(
      jsonEncode(model.requests.single),
      isNot(contains('https://images.example')),
    );
    expect(
      http.requests.single.headers.keys.map((s) => s.toLowerCase()),
      isNot(contains('authorization')),
    );
    expect(
      jsonEncode(http.requests.map((r) => r.headers).toList()),
      isNot(contains('fixture-secret')),
    );
  });

  test('图片转述模型独立调用，主模型仅收到文字描述，缓存只在同会话生效', () async {
    http.handler = (_) async =>
        (bytes: png, status: 200, headers: <String, String>{});
    model.handler = (_, request) async => fixtures.answer(
      request['model'] == 'vision-model' ? '蓝天里的一只小猫' : '看到了一只小猫',
    );
    final history = [
          message(segments: [picture()]),
        ],
        usage = <int>[];
    final settings = preset({
      'imageDescriptionProviderId': 'vision',
      'imageMaxEdge': 512,
    });
    await reply(
      settings: settings,
      caption: vision,
      history: history,
      usage: (a, b) => usage.add(a + b),
    );
    expect(model.requests.map((r) => r['model']), [
      'vision-model',
      'text-model',
    ]);
    expect(jsonEncode(model.requests.last), contains('蓝天里的一只小猫'));
    expect(jsonEncode(model.requests.last), isNot(contains('image_url')));
    expect(usage.length, 2);
    await reply(settings: settings, caption: vision, history: history);
    expect(model.requests.where((r) => r['model'] == 'vision-model').length, 1);
    final other = AgentSession(
      connectionId: 'b',
      selfId: '10002',
      kind: 'group',
      peerId: '20002',
      name: '同群其他机器人',
    );
    await reply(
      settings: settings,
      caption: vision,
      chat: other,
      history: [
        message(segments: [picture()], chat: other),
      ],
    );
    expect(model.requests.where((r) => r['model'] == 'vision-model').length, 2);
  });

  test('文本模型不下载图片；不可用图片明确标注失败，不编造视觉结果', () async {
    await reply(
      history: [
        message(segments: [picture()]),
      ],
    );
    expect(http.requests, isEmpty);
    final notices = <String>[];
    http.handler = (_) async => page('Expired link', status: 403);
    await reply(
      main: vision,
      history: [
        message(segments: [picture()]),
      ],
      notice: notices.add,
    );
    expect(jsonEncode(model.requests.last), contains('不可猜测图片内容'));
    expect(notices.single, contains('HTTP 403'));
  });

  test('每轮最多处理6张图片，重复图片只下载一次', () async {
    http.handler = (_) async =>
        (bytes: png, status: 200, headers: <String, String>{});
    final messages = [
      for (var i = 0; i < 4; i++)
        message(segments: [picture(), picture(), picture()]),
    ];
    await reply(
      main: vision,
      settings: preset({'imageMaxEdge': 256}),
      history: messages,
    );
    expect(http.requests, hasLength(1));
    expect(
      '"image_url":'.allMatches(jsonEncode(model.requests.single)).length,
      6,
    );
    expect(jsonEncode(model.requests.single), contains('本轮最多处理 6 张'));
  });

  test('模型返回的思考单独收集，QQ正文仅最终答案；关闭后不收集', () async {
    model.handler = (_, _) async => {
      'choices': [
        {
          'message': {
            'content': '<think>旧兼容块</think>最终答案',
            'reasoning_content': '接口返回的简短分析',
          },
        },
      ],
    };
    final reasoning = <String>[];
    expect(
      await reply(
        settings: preset({'showReasoning': true}),
        reasoning: reasoning.add,
      ),
      '最终答案',
    );
    expect(reasoning.single, contains('接口返回的简短分析'));
    expect(reasoning.single, contains('旧兼容块'));
    reasoning.clear();
    expect(
      await reply(
        settings: preset({'showReasoning': false}),
        reasoning: reasoning.add,
      ),
      '最终答案',
    );
    expect(reasoning, isEmpty);
    expect(jsonEncode(model.requests.last), isNot(contains('接口返回的简短分析')));
  });

  test('思考摘要和分段内容兼容；仅思考无正文不冒充答案', () async {
    const example = '示例代码：\n```html\n<think>example</think>\n```';
    expect(agentModelText({'content': example}).answer, example);
    expect(
      agentModelText({
        'content': [
          {'type': 'thinking', 'thinking': '模型返回摘要'},
          {'type': 'text', 'text': '答案'},
        ],
      }),
      (answer: '答案', reasoning: '模型返回摘要'),
    );
    expect(
      agentModelText({'content': '答案', 'reasoning_summary': '返回摘要'}).reasoning,
      '返回摘要',
    );
    model.handler = (_, _) async => fixtures.answer('<think>没有结束的思考');
    await expectLater(
      reply(settings: preset({'showReasoning': true})),
      throwsA(isA<AgentException>()),
    );
    model.handler = (_, _) async => fixtures.answer('普通正文');
    final notices = <String>[];
    await reply(settings: preset({'showReasoning': true}), notice: notices.add);
    expect(notices.single, contains('未返回可显示'));
  });

  test('Bing结果解析保留来源、解码跳转链接、过滤伪链接', () {
    final encoded = base64Url.encode(
      utf8.encode('https://docs.example/guide?q=1&x=2'),
    );
    final results = parseBingResults('''<ol>
      <li class="b_algo extra"><h2><a href="https://www.bing.com/ck/a?u=a1$encoded">官方 &amp; 指南</a></h2><div class="b_caption"><p>文档摘要</p></div></li>
      <li class="b_algo"><h2><a href="javascript:alert(1)">坏链接</a></h2></li>
      <li class="b_algo"><h2><a href="https://docs.example/guide?q=1&amp;x=2">重复</a></h2></li>
    </ol>''');
    expect(results, hasLength(1));
    expect(results.single['title'], '官方 & 指南');
    expect(results.single['url'], 'https://docs.example/guide?q=1&x=2');
    expect(results.single['snippet'], '文档摘要');
  });

  test('网页正文去脚本、表单和导航，按长度截断', () {
    final body = extractWebPage(
      '<html><title>测试文档</title><nav>导航</nav><script>secret()</script><article><p>可读正文</p><form>密码</form>${'文' * 9000}</article></html>',
    );
    expect(body, contains('测试文档'));
    expect(body, contains('可读正文'));
    expect(body, isNot(contains('secret')));
    expect(body, isNot(contains('密码')));
    expect(body.length, lessThanOrEqualTo(7000));
  });

  test('Bing主节点无结果才尝试另一个，均失败时不伪造结果', () async {
    http.handler = (uri) async => uri.host == 'cn.bing.com'
        ? page('<html>verification required</html>')
        : page(
            '<li class="b_algo"><h2><a href="https://example.com/doc">官方文档</a></h2><p>摘要</p></li>',
          );
    final web = AgentWeb(http),
        result = await web.search('QQ bot 最新文档', CancelToken());
    expect(result['results'], hasLength(1));
    expect(http.requests.map((r) => r.uri.host), [
      'cn.bing.com',
      'www.bing.com',
    ]);
    expect(http.requests.last.uri.queryParameters['q'], 'QQ bot 最新文档');
    http.handler = (_) async => page('captcha', status: 403);
    await expectLater(
      web.search('QQ bot', CancelToken()),
      throwsA(isA<AgentException>()),
    );
  });

  test('内置web_search工具参与实际模型循环，不给搜索服务发送聊天正文或密钥', () async {
    http.handler = (_) async => page(
      '<li class="b_algo"><h2><a href="https://docs.example">文档</a></h2><p>资料</p></li>',
    );
    model.handler = (round, request) async {
      if (round == 1) {
        expect(
          (request['tools'] as List).map((t) => object(t['function'])['name']),
          containsAll(['web_search', 'web_fetch']),
        );
        return {
          'choices': [
            {
              'message': {
                'content': null,
                'reasoning_content': '接口返回的搜索计划',
                'tool_calls': [
                  {
                    'id': 'call-search',
                    'type': 'function',
                    'function': {
                      'name': 'web_search',
                      'arguments': jsonEncode({'query': 'QQ 文档'}),
                    },
                  },
                ],
              },
            },
          ],
        };
      }
      final messages = (request['messages'] as List).map(object).toList();
      expect(messages.last['role'], 'tool');
      expect(messages.last['content'], contains('https://docs.example'));
      expect(messages[messages.length - 2]['reasoning_content'], '接口返回的搜索计划');
      return fixtures.answer('请看文档 https://docs.example');
    };
    final reasoning = <String>[];
    await reply(
      settings: preset({'webSearchEnabled': true, 'showReasoning': true}),
      history: [
        message(segments: [textSegment('fixture-private-chat 请搜索QQ文档')]),
      ],
      reasoning: reasoning.add,
    );
    expect(http.requests.single.uri.queryParameters['q'], 'QQ 文档');
    expect(
      http.requests.single.uri.toString(),
      isNot(contains('fixture-private-chat')),
    );
    expect(
      jsonEncode(http.requests.single.headers),
      isNot(contains('fixture-secret')),
    );
    expect(reasoning.single, '接口返回的搜索计划');
  });

  test('搜索关闭或模型不支持工具时不暴露工具，重名Skill明确报错', () async {
    await reply();
    expect(model.requests.last.containsKey('tools'), false);
    final noTools = AgentProvider.fromJson({
      ...provider.toJson(),
      'tools': false,
    });
    final notices = <String>[];
    await reply(
      main: noTools,
      settings: preset({'webSearchEnabled': true}),
      notice: notices.add,
    );
    expect(model.requests.last.containsKey('tools'), false);
    expect(notices.single, contains('未启用工具调用'));
    final duplicate = AgentExtension({
      'id': 'search',
      'kind': 'skill',
      'name': '搜索',
      'tools': [AgentWeb.definitions.first],
    }, enabled: true);
    await expectLater(
      reply(
        settings: preset({
          'webSearchEnabled': true,
          'skillIds': ['search'],
        }),
        skills: [duplicate],
      ),
      throwsA(isA<AgentException>()),
    );
  });

  test('网页工具拒绝降级HTTP、带密码链接、二进制和无限重定向', () async {
    final web = AgentWeb(http);
    for (final url in [
      'http://example.com/',
      'https://user:pass@example.com/',
    ]) {
      await expectLater(
        web.fetch(url, CancelToken()),
        throwsA(isA<AgentException>()),
      );
    }
    expect(http.requests, isEmpty);
    http.handler = (_) async =>
        page('binary', headers: {'content-type': 'image/png'});
    await expectLater(
      web.fetch('https://example.com/pic', CancelToken()),
      throwsA(isA<AgentException>()),
    );
    http.handler = (_) async => page(
      '',
      status: 302,
      headers: {'location': 'http://example.com/plain'},
    );
    await expectLater(
      web.fetch('https://example.com/', CancelToken()),
      throwsA(isA<AgentException>()),
    );
    final before = http.requests.length;
    http.handler = (_) async =>
        page('', status: 302, headers: {'location': '/again'});
    await expectLater(
      web.fetch('https://example.com/', CancelToken()),
      throwsA(isA<AgentException>()),
    );
    expect(http.requests.length - before, 4);
  });

  test('真实公开下载器拒绝回环/内网，不发出网络请求', () async {
    final real = AgentHttp();
    try {
      for (final url in [
        'https://127.0.0.1/test',
        'https://192.168.1.2/test',
        'https://[::1]/test',
      ]) {
        await expectLater(
          agentPublicGet(
            real,
            Uri.parse(url),
            cancel: CancelToken(),
            maxBytes: 100,
          ),
          throwsA(isA<AgentException>()),
        );
      }
    } finally {
      real.close();
    }
  });

  test('转述途中停止不再请求主模型，取消不会被当作普通图片失败吞掉', () async {
    http.handler = (_) async =>
        (bytes: png, status: 200, headers: <String, String>{});
    final entered = Completer<void>(), release = Completer<Json>();
    model.handler = (_, _) {
      entered.complete();
      return release.future;
    };
    final turn = AgentTurn(() => true);
    final work = reply(
      caption: vision,
      settings: preset({
        'imageDescriptionProviderId': 'vision',
        'imageMaxEdge': 256,
      }),
      history: [
        message(segments: [picture()]),
      ],
      turn: turn,
    );
    final expected = expectLater(work, throwsA(isA<AgentException>()));
    await entered.future;
    turn.stop();
    release.complete(fixtures.answer('旧转述'));
    await expected;
    expect(model.requests, hasLength(1));
  });

  group('控制器集成', () {
    late AgentController agent;
    late Map<String, fixtures.FakeAgentTransport> transports;
    setUp(() async {
      transports = {};
      agent = AgentController(
        store: AgentStore.memory(),
        model: model,
        http: http,
        transportFactory: (c) =>
            transports[c.id] = fixtures.FakeAgentTransport(c),
      );
      await agent.initialize();
      await agent.saveProvider(provider);
      await agent.saveProvider(vision);
      await agent.savePreset(preset());
    });
    tearDown(() async {
      await agent.shutdown();
      agent.dispose();
    });
    Future<fixtures.FakeAgentTransport> connect(Json changes) async {
      await agent.saveConnection(
        AgentConnection.fromJson({
          ...AgentConnection(
            id: 'a',
            name: '小助手',
            selfId: '10001',
            aiEnabled: true,
            cooldownSeconds: 0,
          ).toJson(),
          'extraWakePrefixes': ['小助手', 'hey bot'],
          ...changes,
        }),
      );
      await agent.connect('a');
      return transports['a']!;
    }

    test('免@唤醒有回复，群聊关闭/白名单/暂停/AI关闭仍拦截', () async {
      var t = await connect({});
      t.receive(id: 'prefix', mention: false, content: '小助手你好');
      await fixtures.eventually(() => t.sent.isNotEmpty);
      expect(model.requests, hasLength(1));
      for (final changes in [
        <String, dynamic>{'groupTrigger': 'off'},
        {
          'groupAllowlist': ['99999'],
        },
        {
          'userAllowlist': ['99999'],
        },
        {'aiEnabled': false},
      ]) {
        t = await connect(changes);
        final count = model.requests.length;
        t.receive(
          id: 'blocked-$count-${changes.keys.first}',
          mention: false,
          content: 'hey bot 你好',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(t.sent, isEmpty);
        expect(model.requests, hasLength(count));
      }
      t = await connect({});
      final s = agent.sessions().single..paused = true;
      await agent.configureSession(s);
      t.receive(id: 'paused', mention: false, content: '小助手你好');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(t.sent, isEmpty);
    });
    test('思考持久化仅本地，发送段/下一轮上下文无思考，关闭后新回复不保留', () async {
      await agent.savePreset(preset({'showReasoning': true}));
      model.handler = (_, _) async => {
        'choices': [
          {
            'message': {
              'content': '你好',
              'reasoning_content': 'fixture-private-reasoning',
            },
          },
        ],
      };
      final t = await connect({});
      t.receive();
      await fixtures.eventually(
        () =>
            agent.sessions().isNotEmpty &&
            agent.store
                .messages(agent.sessions().single.key)
                .any((m) => m.outgoing),
      );
      final key = agent.sessions().single.key;
      final outgoing = agent.store.messages(key).last;
      expect(outgoing.reasoning, 'fixture-private-reasoning');
      expect(
        AgentMessage.fromJson(outgoing.toJson()).reasoning,
        outgoing.reasoning,
      );
      expect(
        jsonEncode(t.sent.single),
        isNot(contains('fixture-private-reasoning')),
      );
      t.receive(id: 'second');
      await fixtures.eventually(() => t.sent.length == 2);
      expect(
        jsonEncode(model.requests.last),
        isNot(contains('fixture-private-reasoning')),
      );
      await agent.savePreset(preset({'showReasoning': false}));
      t.receive(id: 'third');
      await fixtures.eventually(
        () => agent.store.messages(key).where((m) => m.outgoing).length == 3,
      );
      expect(agent.store.messages(key).last.reasoning, isEmpty);
    });
    test('转述配置引用必须有效，删除被引用视觉模型被阻止', () async {
      await expectLater(
        agent.savePreset(preset({'imageDescriptionProviderId': 'missing'})),
        throwsA(isA<AgentException>()),
      );
      await expectLater(
        agent.savePreset(preset({'imageDescriptionProviderId': 'text'})),
        throwsA(isA<AgentException>()),
      );
      await agent.savePreset(preset({'imageDescriptionProviderId': 'vision'}));
      await expectLater(
        agent.deleteProvider('vision'),
        throwsA(isA<AgentException>()),
      );
    });
  });
}
