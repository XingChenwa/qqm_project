import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/agent/ai.dart';
import 'package:qq_bot_manager/agent/completion_stream.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/reply_format.dart';
import 'package:qq_bot_manager/agent/script.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/videos.dart';
import 'package:qq_bot_manager/agent/web.dart';
import 'agent_core_test.dart' as f;

class SearchVideoHttp extends AgentHttp {
  final requests = <Json>[], downloads = <Json>[];
  Object? response;
  bool fail = false;
  Uint8List video = Uint8List.fromList([0, 0, 0, 24, 102, 116, 121, 112]);
  @override
  Future<List<InternetAddress>> validatePublicUri(Uri uri) async {
    if (uri.scheme != 'https' ||
        uri.host == '127.0.0.1' ||
        uri.host == 'localhost') {
      throw const AgentException('测试拒绝内网地址');
    }
    return [InternetAddress('8.8.8.8')];
  }

  @override
  Future<dynamic> request(
    Uri uri, {
    String method = 'GET',
    Json? body,
    Map<String, String> headers = const {},
    Json? query,
    CancelToken? cancel,
    int timeoutSeconds = 60,
    int maxBytes = 1048576,
  }) async {
    requests.add({
      'url': uri.toString(),
      'method': method,
      'body': body,
      'headers': headers,
    });
    if (fail) {
      throw const AgentHttpException('fixture HTTP 402', statusCode: 402);
    }
    return response ??
        {
          'results': [
            {
              'title': '官方结果',
              'url': 'https://example.com/news',
              'summary': '真实摘要',
              'content': '网页正文',
            },
          ],
        };
  }

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
    await validatePublicUri(uri);
    downloads.add({
      'url': uri.toString(),
      'headers': headers,
      'maxBytes': maxBytes,
    });
    return (bytes: video, status: 200, headers: {'content-type': 'video/mp4'});
  }
}

AgentProvider deepseek({String base = 'https://api.deepseek.com/v1'}) =>
    AgentProvider(
      id: 'search',
      name: '官方搜索',
      baseUrl: base,
      model: 'fixture-model',
      apiKey: 'fixture-deepseek-key',
    );
AgentPreset preset([Json extra = const {}]) => AgentPreset.fromJson({
  'id': 'p',
  'name': '预设',
  'prompt': '根据实际内容回答',
  'providerId': 'main',
  ...extra,
});
AgentProvider visual({bool native = false, bool audio = false}) =>
    AgentProvider(
      id: 'visual',
      name: '视频模型',
      baseUrl: 'https://model.example/v1',
      model: 'fixture-vision',
      vision: !native,
      video: native,
      videoAudio: audio,
      apiKey: 'fixture-video-key',
    );
Uint8List picture(int red) => Uint8List.fromList(
  img.encodePng(
    img.Image(width: 64, height: 32)..clear(img.ColorRgb8(red, 20, 200)),
  ),
);
AgentVideoSample samples() => AgentVideoSample(6, [
  for (var i = 0; i < 6; i++) AgentVideoFrame(i + .5, picture(i * 40)),
]);
Json toolReply(String name, Json args) => {
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': 'tool-1',
            'type': 'function',
            'function': {'name': name, 'arguments': jsonEncode(args)},
          },
        ],
      },
    },
  ],
};

void main() {
  test('分条回复拒绝空数组、混入思考的残缺JSON与错误类型，正常正文仍可发送', () {
    for (final source in [
      '{"messages":[]}',
      '{"messages":[]}The user @ someone',
      '{"messages":[1]}',
    ]) {
      expect(
        () => agentReplyMessages(source, enabled: true),
        throwsA(isA<AgentException>()),
      );
    }
    expect(agentReplyMessages('The user manual is available.', enabled: true), [
      'The user manual is available.',
    ]);
  });
  test('机器人自我身份和当前@事实提供给模型，官机AppID不冒充用户QQ号', () async {
    final http = SearchVideoHttp(),
        model = f.FakeAgentModel(),
        scripts = AgentScripts();
    final ai = AgentAi(model, AgentExtensions(http, scripts));
    for (final mode in ['self', 'other', 'qqbot']) {
      final session = AgentSession(
        connectionId: 'a',
        selfId: '1904104647',
        protocol: mode == 'qqbot' ? 'qqbot' : 'onebot',
        kind: 'group',
        peerId: '20002',
        name: '群',
      );
      final message = AgentMessage(
        id: 'trigger',
        sessionKey: session.key,
        senderId: '30003',
        senderName: '川',
        addressed: mode == 'qqbot',
        segments: [
          textSegment('oi'),
          {
            'type': 'at',
            'data': {'qq': mode == 'self' ? '1904104647' : '40004'},
          },
        ],
      );
      await ai.reply(
        provider: deepseek(),
        preset: preset(),
        session: session,
        history: [message],
        triggerMessage: message,
        skills: [],
        turn: AgentTurn(() => true),
        onUsage: (_, _) {},
        onTool: (_) {},
      );
      final body = jsonEncode(model.requests.last['messages']);
      expect(body, contains(mode == 'other' ? '没有直接@你' : '直接@了你：被@的就是你'));
      expect(
        body,
        contains(mode == 'qqbot' ? 'AppID不是用户QQ号' : '你自己的QQ号是1904104647'),
      );
    }
    scripts.close();
    http.close();
  });
  test('搜索/视频配置兼容旧预设，保存能力与SSE参数，拒绝错误组合', () {
    final old = preset();
    expect(old.webSearchBackend, 'bing');
    expect(old.videoFrames, 6);
    expect(old.videoUnderstandingEnabled, true);
    final p = preset({
      'webSearchBackend': 'deepseek',
      'webSearchProviderId': 'search',
      'videoProviderId': 'visual',
      'videoFrames': 8,
    });
    expect(AgentPreset.fromJson(p.toJson()).toJson(), p.toJson());
    final v = AgentProvider.fromJson({
      ...visual(native: true, audio: true).toJson(),
      'stream': true,
    });
    expect(v.video, true);
    expect(v.videoAudio, true);
    expect(v.stream, true);
    v.validate();
    expect(
      () => preset({'videoFrames': 1}).validate(),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => AgentProvider.fromJson({...v.toJson(), 'video': false}).validate(),
      throwsA(isA<AgentException>()),
    );
  });

  test('DeepSeek调用官方Search/Fetch，保留真实来源且不把密钥放进模型结果', () async {
    final http = SearchVideoHttp(), web = AgentWeb(SearchVideoHttp());
    final service = AgentWeb(http);
    final result = await service.execute(
      'web_search',
      {'query': 'QQ机器人新功能'},
      CancelToken(),
      backend: 'deepseek',
      searchProvider: deepseek(),
    );
    expect(
      http.requests.single['url'],
      'https://api.deepseek.com/v1/tools/search',
    );
    expect(http.requests.single['body'], {
      'query': 'QQ机器人新功能',
      'count': 5,
      'need_content': true,
    });
    expect(
      object(http.requests.single['headers'])['Authorization'],
      'Bearer fixture-deepseek-key',
    );
    expect(result['text'], contains('https://example.com/news'));
    expect(result['text'], isNot(contains('fixture-deepseek-key')));
    http.response = {'title': '页面', 'content': '# 真实网页正文'};
    expect(
      (await service.execute(
        'web_fetch',
        {'url': 'https://example.com/a'},
        CancelToken(),
        backend: 'deepseek',
        searchProvider: deepseek(),
      ))['text'],
      contains('真实网页正文'),
    );
    expect(
      http.requests.last['url'],
      'https://api.deepseek.com/v1/tools/fetch',
    );
    await expectLater(
      web.execute(
        'web_search',
        {'query': 'test'},
        CancelToken(),
        backend: 'deepseek',
      ),
      throwsA(isA<AgentException>()),
    );
    http.close();
    web.http.close();
  });

  test('DeepSeek拒绝把中转密钥转交官方、超长搜索及内网页面；失败和空结果不伪造', () async {
    final http = SearchVideoHttp(), web = AgentWeb(SearchVideoHttp());
    final service = AgentWeb(http);
    await expectLater(
      service.execute(
        'web_search',
        {'query': '测试'},
        CancelToken(),
        backend: 'deepseek',
        searchProvider: deepseek(base: 'https://proxy.example/v1'),
      ),
      throwsA(isA<AgentException>()),
    );
    await expectLater(
      service.execute(
        'web_search',
        {'query': List.filled(129, '测').join()},
        CancelToken(),
        backend: 'deepseek',
        searchProvider: deepseek(),
      ),
      throwsA(isA<AgentException>()),
    );
    await expectLater(
      service.execute(
        'web_fetch',
        {'url': 'https://127.0.0.1/a'},
        CancelToken(),
        backend: 'deepseek',
        searchProvider: deepseek(),
      ),
      throwsA(isA<AgentException>()),
    );
    expect(http.requests, isEmpty);
    http.response = {'results': []};
    final result = object(
      jsonDecode(
        text(
          (await service.execute(
            'web_search',
            {'query': '没结果'},
            CancelToken(),
            backend: 'deepseek',
            searchProvider: deepseek(),
          ))['text'],
        ),
      ),
    );
    expect(result['results'], isEmpty);
    http.fail = true;
    await expectLater(
      service.execute(
        'web_search',
        {'query': '真实错误'},
        CancelToken(),
        backend: 'deepseek',
        searchProvider: deepseek(),
      ),
      throwsA(isA<AgentHttpException>()),
    );
    http.close();
    web.http.close();
  });

  test('DeepSeek搜索参与真实工具循环，使用独立凭证并保持Bing兼容', () async {
    final http = SearchVideoHttp(),
        scripts = AgentScripts(),
        model = f.FakeAgentModel();
    final ai = AgentAi(model, AgentExtensions(http, scripts));
    final session = AgentSession(
      connectionId: 'a',
      selfId: '10001',
      kind: 'group',
      peerId: '20002',
      name: '群',
    );
    model.handler = (round, request) async => round == 1
        ? toolReply('web_search', {'query': '今天新闻'})
        : f.answer('有来源的回答');
    final main = AgentProvider(
      id: 'main',
      name: '主模型',
      baseUrl: 'https://text.example/v1',
      model: 'text',
    );
    final answer = await ai.reply(
      provider: main,
      preset: preset({
        'webSearchEnabled': true,
        'webSearchBackend': 'deepseek',
      }),
      searchProvider: deepseek(),
      session: session,
      history: [
        AgentMessage(
          id: 'm',
          sessionKey: session.key,
          senderId: '30003',
          senderName: '用户',
          segments: [textSegment('搜索今天新闻')],
        ),
      ],
      skills: [],
      turn: AgentTurn(() => true),
      onUsage: (_, _) {},
      onTool: (_) {},
    );
    expect(answer, '有来源的回答');
    expect(http.requests, hasLength(1));
    expect(jsonEncode(model.requests.last), contains('官方结果'));
    expect(jsonEncode(model.requests), isNot(contains('fixture-deepseek-key')));
    expect(
      object(
        object((model.requests.first['tools'] as List).first)['function'],
      )['description'],
      contains('DeepSeek'),
    );
    scripts.close();
    http.close();
  });

  test('SSE合并正文、思考、分片工具参数和用量，不接受中途断开的正文', () async {
    String event(Json chunk) => 'data: ${jsonEncode(chunk)}\r\n\r\n';
    final source =
        '${event({
          'choices': [
            {
              'index': 0,
              'delta': {
                'content': '你好',
                'reasoning_content': '本地思考',
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call-1',
                    'type': 'function',
                    'function': {
                      'name': 'web_search',
                      'arguments': '{"query":',
                    },
                  },
                ],
              },
            },
          ],
        })}${event({
          'choices': [
            {
              'index': 0,
              'delta': {
                'content': '世界',
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': '"新闻"}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        })}${event({
          'choices': [],
          'usage': {'prompt_tokens': 12, 'completion_tokens': 8},
        })}data: [DONE]\n\n';
    final response = agentStreamCompletion(source),
        message = object(
          object((response['choices'] as List).single)['message'],
        );
    expect(message['content'], '你好世界');
    expect(message['reasoning_content'], '本地思考');
    expect(
      object(
        object((message['tool_calls'] as List).single)['function'],
      )['arguments'],
      '{"query":"新闻"}',
    );
    expect(response['usage'], {'prompt_tokens': 12, 'completion_tokens': 8});
    expect(
      () => agentStreamCompletion(
        event({
          'choices': [
            {
              'delta': {'content': '不完整'},
            },
          ],
        }),
      ),
      throwsA(isA<AgentException>()),
    );
    final http = SearchVideoHttp()..response = source;
    final streaming = AgentProvider.fromJson({
      ...visual(native: true).toJson(),
      'stream': true,
    });
    final actual = await CompatibleAgentModel(
      http,
    ).complete(streaming, {'stream': false, 'messages': []}, CancelToken());
    expect(actual['usage'], response['usage']);
    expect(object(http.requests.single['body'])['stream'], true);
    http.close();
  });

  test('原生视频把真实video_url交给视频模型，文本结果带音轨能力边界和用量', () async {
    final http = SearchVideoHttp(), model = f.FakeAgentModel();
    model.handler = (_, _) async => f.answer('00:01 小猫走到桌边，字幕是你好');
    final videos = AgentVideos(http, model);
    var charged = 0;
    final result = await videos.analyze(
      scope: 'chat-a',
      source: 'https://video.example/a.mp4',
      question: '讲了什么',
      provider: visual(native: true, audio: true),
      preset: preset(),
      turn: AgentTurn(() => true),
      onUsage: (_, _) async {
        charged++;
      },
    );
    final parts =
        object((model.requests.single['messages'] as List).last)['content']
            as List;
    expect(
      object(object(parts.last)['video_url'])['url'],
      'https://video.example/a.mp4',
    );
    expect(result['route'], 'native-video');
    expect(result['audioAnalyzed'], true);
    expect(charged, 1);
    expect(http.downloads, isEmpty);
    expect(jsonEncode(model.requests), isNot(contains('fixture-video-key')));
    http.close();
  });

  test('多帧识别传入六张真实画面及时间点，按会话缓存且不声称听到声音', () async {
    final http = SearchVideoHttp(), model = f.FakeAgentModel();
    var extracts = 0, charged = 0;
    final videos = AgentVideos(
      http,
      model,
      frameReader: (bytes, count, cancel) async {
        extracts++;
        expect(count, 6);
        return samples();
      },
    );
    Future<Json> read(String chat) => videos.analyze(
      scope: chat,
      source: 'https://video.example/a.mp4',
      question: '内容',
      provider: visual(),
      preset: preset(),
      turn: AgentTurn(() => true),
      onUsage: (_, _) async {
        charged++;
      },
    );
    final first = await read('chat-a');
    await read('chat-a');
    expect(extracts, 1);
    expect(charged, 1);
    expect(first['route'], 'sampled-frames');
    expect(first['frameCount'], 6);
    expect(first['audioAnalyzed'], false);
    final parts =
        object((model.requests.single['messages'] as List).last)['content']
            as List;
    expect(
      parts.map(object).where((p) => p['type'] == 'image_url'),
      hasLength(6),
    );
    expect(jsonEncode(parts), contains('0.50'));
    expect(jsonEncode(parts), contains('5.50'));
    expect(jsonEncode(model.requests), contains('不可编造对白'));
    expect(object(http.downloads.single['headers'])['Authorization'], isNull);
    await read('chat-b');
    expect(charged, 2);
    http.close();
  });

  test('只有封面、重复时间点、超限视频和取消不会产生虚假的视频分析', () async {
    final http = SearchVideoHttp(), model = f.FakeAgentModel();
    var sample = AgentVideoSample(6, [AgentVideoFrame(.5, picture(0))]);
    final videos = AgentVideos(
      http,
      model,
      frameReader: (_, _, _) async => sample,
    );
    Future<Json> read(AgentTurn turn) => videos.analyze(
      scope: 'a',
      source: 'https://video.example/v.mp4',
      question: '内容',
      provider: visual(),
      preset: preset(),
      turn: turn,
      onUsage: (_, _) async {},
    );
    await expectLater(
      read(AgentTurn(() => true)),
      throwsA(isA<AgentException>()),
    );
    sample = AgentVideoSample(6, [
      AgentVideoFrame(.5, picture(0)),
      AgentVideoFrame(.5, picture(50)),
    ]);
    await expectLater(
      read(AgentTurn(() => true)),
      throwsA(isA<AgentException>()),
    );
    final stopped = AgentTurn(() => true)..stop();
    await expectLater(read(stopped), throwsA(isA<AgentException>()));
    expect(model.requests, isEmpty);
    http.close();
  });

  for (final protocol in ['onebot', 'qqbot']) {
    for (final split in [false, true]) {
      test('$protocol分条开关为$split时空messages都不会发到QQ，非空包正确解析', () async {
        final model = f.FakeAgentModel();
        late f.FakeAgentTransport transport;
        final agent = AgentController(
          store: AgentStore.memory(),
          model: model,
          transportFactory: (c) => transport = f.FakeAgentTransport(c),
        );
        try {
          await agent.initialize();
          await agent.saveProvider(
            AgentProvider(
              id: 'main',
              name: '文本',
              baseUrl: 'https://text.example/v1',
              model: 'text',
              tools: false,
            ),
          );
          await agent.savePreset(
            preset({'multiMessageReply': split, 'replyIntervalMs': 0}),
          );
          await agent.saveConnection(
            AgentConnection(
              id: 'a',
              name: '机器人',
              selfId: '10001',
              protocol: protocol,
              clientSecret: protocol == 'qqbot' ? 'fixture-only' : '',
              presetId: 'p',
            ),
          );
          await agent.connect('a');
          final s = await agent.openSession('a', 'group', '20002');
          await agent.store.append(
            AgentMessage(
              id: 'ob:mention',
              sessionKey: s.key,
              senderId: '30003',
              senderName: '川',
              segments: [
                {
                  'type': 'at',
                  'data': {'qq': '10001'},
                },
                textSegment('oi'),
              ],
            ),
          );
          model.handler = (_, _) async => f.answer('{"messages":[]}');
          await agent.regenerate(s.key);
          for (
            var i = 0;
            i < 100 && agent.replyState(s.key)['phase'] != 'error';
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(model.requests, hasLength(1));
          expect(agent.replyState(s.key)['phase'], 'error');
          expect(transport.sent, isEmpty);
          expect(agent.store.messages(s.key).where((m) => m.outgoing), isEmpty);
          model.handler = (_, _) async => f.answer('{"messages":["来了","什么事"]}');
          await agent.regenerate(s.key);
          for (
            var i = 0;
            i < 100 && transport.sent.length < (split ? 2 : 1);
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(transport.sent, hasLength(split ? 2 : 1));
          expect(jsonEncode(transport.sent), isNot(contains('"messages"')));
          expect(jsonEncode(transport.sent), contains('来了'));
        } finally {
          await agent.shutdown();
          agent.dispose();
        }
      });
    }
    test('$protocol新视频自动分析，文本主模型读取结果，旧视频工具保持同会话隔离', () async {
      final http = SearchVideoHttp(), model = f.FakeAgentModel();
      late f.FakeAgentTransport transport;
      final agent = AgentController(
        store: AgentStore.memory(),
        http: http,
        model: model,
        transportFactory: (c) => transport = f.FakeAgentTransport(c),
      );
      try {
        await agent.initialize();
        await agent.saveProvider(
          AgentProvider(
            id: 'main',
            name: '文本',
            baseUrl: 'https://text.example/v1',
            model: 'text',
            tools: false,
          ),
        );
        await agent.saveProvider(visual(native: true));
        await agent.savePreset(preset({'videoProviderId': 'visual'}));
        await agent.saveConnection(
          AgentConnection(
            id: 'a',
            name: '机器人',
            selfId: '10001',
            protocol: protocol,
            clientSecret: protocol == 'qqbot' ? 'fixture-only' : '',
            presetId: 'p',
          ),
        );
        await agent.connect('a');
        final s = await agent.openSession('a', 'group', '20002');
        await agent.store.append(
          AgentMessage(
            id: 'ob:trigger',
            sessionKey: s.key,
            senderId: '30003',
            senderName: '用户',
            segments: [
              textSegment('这段视频讲什么'),
              {
                'type': 'video',
                'data': {'url': 'https://video.example/a.mp4'},
              },
            ],
          ),
        );
        model.handler = (_, request) async {
          final parts = object((request['messages'] as List).last)['content'];
          if (parts is List &&
              parts.map(object).any((p) => p['type'] == 'video_url')) {
            return f.answer('真实分析：小猫跳上桌面。');
          }
          expect(jsonEncode(request), contains('真实分析：小猫跳上桌面。'));
          return f.answer('视频里小猫跳上桌面。');
        };
        await agent.regenerate(s.key);
        for (var i = 0; i < 100 && transport.sent.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(model.requests, hasLength(2));
        expect(transport.sent, hasLength(1));
        final other = await agent.openSession('a', 'group', '40004');
        await expectLater(
          agent.executeBuiltinTool(other.key, 'read_video', {
            'messageId': 'ob:trigger',
          }, preset: preset({'videoProviderId': 'visual'})),
          throwsA(isA<AgentException>()),
        );
        await expectLater(
          agent.deleteProvider('visual'),
          throwsA(isA<AgentException>()),
        );
      } finally {
        await agent.shutdown();
        agent.dispose();
      }
    });
  }
}
