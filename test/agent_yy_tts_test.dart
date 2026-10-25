import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/ui/editor.dart';
import 'agent_audio_test.dart' show sampleWav;
import 'agent_core_test.dart' as fixture;

Future<Uint8List> yyTtsBundle() async {
  final archive = Archive();
  for (final name in ['skill.json', 'index.js', 'service.json', 'README.md']) {
    final bytes = await File('agent_examples/yy-tts/$name').readAsBytes();
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class YyTtsHttp extends AgentHttp {
  @override
  Future<List<InternetAddress>> validatePublicUri(Uri uri) async {
    if (uri.host == 'yy.jujiang.js.cn') return [InternetAddress('203.0.113.1')];
    return super.validatePublicUri(uri);
  }

  final requests = <({Uri uri, Object? body})>[];
  final submitted = <List<dynamic>>[];
  bool fail = false,
      invalidAudio = false,
      incomplete = false,
      useQueue = true,
      metadataFail = false,
      directJson = false,
      directRedirect = false,
      directLoop = false;
  final sessions = <String, String>{};
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
    requests.add((uri: uri, body: body));
    expect(uri.scheme, 'https');
    expect(
      headers.keys.map((s) => s.toLowerCase()),
      isNot(contains('authorization')),
    );
    Object result;
    if (uri.path.endsWith('/tts')) {
      expect(method, 'GET');
      expect(body, isNull);
      expect(uri.queryParameters.keys.toSet(), {'character', 'text', 'speed'});
      if (fail) {
        return (bytes: Uint8List(0), status: 503, headers: <String, String>{});
      }
      if (directRedirect) {
        return (
          bytes: Uint8List(0),
          status: 302,
          headers: {
            'location': directLoop
                ? '/%74ts?text=again'
                : '/generated/voice.wav',
          },
        );
      }
      if (directJson) {
        return (
          bytes: Uint8List.fromList(
            utf8.encode('{"audio_url":"/generated/voice.wav"}'),
          ),
          status: 200,
          headers: {'content-type': 'application/json'},
        );
      }
      return (
        bytes: invalidAudio
            ? Uint8List.fromList(utf8.encode('<html>not audio</html>'))
            : sampleWav(),
        status: 200,
        headers: {'content-type': invalidAudio ? 'text/html' : 'audio/wav'},
      );
    } else if (uri.path == '/config') {
      if (metadataFail) {
        return (
          bytes: Uint8List.fromList(utf8.encode('{}')),
          status: 503,
          headers: {'content-type': 'application/json'},
        );
      }
      result = {
        'version': '4.37.2',
        if (useQueue) 'protocol': 'sse_v3',
        'dependencies': [
          {
            'id': 4,
            'api_name': 'get_audio',
            'inputs': List.generate(17, (i) => i),
          },
          {
            'id': 1,
            'api_name': 'load_character_emotions',
            'inputs': [1, 12],
          },
        ],
        'components': [
          {
            'id': 1,
            'props': {
              'choices': [
                ['11号', '11号'],
                ['七七', '七七'],
              ],
            },
          },
        ],
      };
    } else if (uri.path == '/queue/join') {
      final payload = jsonDecode(body as String) as Map;
      final audio = payload['fn_index'] == 4;
      expect(payload['fn_index'], anyOf(4, 1));
      expect(payload['event_data'], isNull);
      if (!audio) {
        expect(payload['data'], ['11号', null]);
      }
      if (audio) submitted.add(payload['data'] as List);
      final id = audio ? 'test-audio' : 'test-emotions';
      sessions[payload['session_hash'] as String] = id;
      return (
        bytes: Uint8List.fromList(utf8.encode(jsonEncode({'event_id': id}))),
        status: fail && audio ? 503 : 200,
        headers: {'content-type': 'application/json'},
      );
    } else if (uri.path == '/queue/data') {
      expect(headers['Accept-Encoding'], 'identity');
      final id = sessions[uri.queryParameters['session_hash']];
      expect(id, isNotNull);
      final data = id == 'test-emotions'
          ? [
              {
                'choices': ['default', '开心'],
              },
            ]
          : [
              {
                'path': '/tmp/gradio/audio.wav',
                'url': 'https://yy.jujiang.js.cn/file=/tmp/gradio/audio.wav',
              },
            ];
      final packet = incomplete
          ? {'msg': 'heartbeat'}
          : {
              'msg': 'process_completed',
              'event_id': id,
              'success': true,
              'output': {'data': data},
            };
      return (
        bytes: Uint8List.fromList(
          utf8.encode('data: ${jsonEncode(packet)}\n\n'),
        ),
        status: 200,
        headers: {'content-type': 'text/event-stream'},
      );
    } else if (uri.path == '/call/get_audio') {
      submitted.add((jsonDecode(body as String) as Map)['data'] as List);
      return (
        bytes: Uint8List.fromList(
          utf8.encode(jsonEncode({'event_id': 'test-audio'})),
        ),
        status: fail ? 503 : 200,
        headers: {'content-type': 'application/json'},
      );
    } else if (uri.path == '/call/load_character_emotions') {
      result = {'event_id': 'test-emotions'};
    } else if (uri.path.endsWith('/test-emotions')) {
      return (
        bytes: Uint8List.fromList(
          utf8.encode(
            'event: complete\ndata: [{"choices":["default","开心"]}]\n\n',
          ),
        ),
        status: 200,
        headers: {'content-type': 'text/event-stream'},
      );
    } else if (uri.path.endsWith('/test-audio')) {
      return (
        bytes: Uint8List.fromList(
          utf8.encode(
            incomplete
                ? 'event: heartbeat\ndata: null\n\n'
                : 'event: heartbeat\ndata: null\n\nevent: complete\ndata: [{"path":"/tmp/gradio/audio.wav","url":"https://yy.jujiang.js.cn/file=/tmp/gradio/audio.wav"}]\n\n',
          ),
        ),
        status: 200,
        headers: {'content-type': 'text/event-stream'},
      );
    } else if (uri.path.startsWith('/file=') ||
        uri.path == '/generated/voice.wav') {
      return (
        bytes: invalidAudio
            ? Uint8List.fromList(utf8.encode('<html>not audio</html>'))
            : sampleWav(),
        status: 200,
        headers: {'content-type': invalidAudio ? 'text/html' : 'audio/wav'},
      );
    } else {
      throw StateError('Unexpected fixture request');
    }
    return (
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(result))),
      status: 200,
      headers: {'content-type': 'application/json'},
    );
  }
}

class YyTransport extends fixture.FakeAgentTransport {
  bool failVoice = false;
  bool emptyVoiceId = false;
  YyTransport(super.config);
  @override
  Future<dynamic> call(String action, [Json params = const {}]) async {
    final voice = jsonEncode(params['message']).contains('"record"');
    if (failVoice && voice) {
      throw const AgentException('协议端未返回语音回执');
    }
    final result = await super.call(action, params);
    return emptyVoiceId && voice ? <String, dynamic>{} : result;
  }
}

void main() {
  testWidgets('大量音色通过搜索选择，保存的是角色值且不影响模型选择文案', (tester) async {
    Json? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => editAgent(
                context,
                title: '语音设置',
                initial: {'character': '11号'},
                fields: [
                  AgentField(
                    'character',
                    '角色音色',
                    type: 'choice',
                    choices: {
                      '11号': '11号',
                      for (var i = 0; i < 50; i++) 'role-$i': '音色$i',
                    },
                  ),
                ],
                save: (j) async {
                  saved = j;
                },
              ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('11号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '搜索角色音色'), '音色49');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '音色49'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved?['character'], 'role-49');
    expect(tester.takeException(), isNull);
  });

  group(
    'YY TTS 原包与完整 AI 工具流程',
    () {
      late AgentController agent;
      late YyTtsHttp http;
      late fixture.FakeAgentModel model;
      late YyTransport transport;
      late AgentExtension extension;
      var received = 0;
      setUp(() async {
        http = YyTtsHttp();
        model = fixture.FakeAgentModel();
        agent = AgentController(
          store: AgentStore.memory(),
          http: http,
          model: model,
          transportFactory: (c) => transport = YyTransport(c),
        );
        await agent.initialize();
        await agent.importPackage(await yyTtsBundle());
        extension = agent.extensions.firstWhere((e) => e.id == 'yy-tts');
        await agent.saveExtension(
          extension.copyWith(
            enabled: true,
            settings: {
              'mode': 'gradio',
              'character': '11号',
              'delivery': 'download',
            },
          ),
        );
        await agent.saveProvider(
          AgentProvider(
            id: 'model',
            name: 'fixture',
            baseUrl: 'http://127.0.0.1:1/v1',
            model: 'fixture',
          ),
        );
        await agent.savePreset(
          AgentPreset(
            id: 'assistant',
            name: 'fixture',
            prompt: '按真实结果回复',
            providerId: 'model',
            skillIds: [extension.id],
          ),
        );
        await agent.saveConnection(
          AgentConnection(
            id: 'qq',
            name: 'fixture',
            selfId: '10001',
            aiEnabled: true,
            cooldownSeconds: 0,
          ),
        );
        await agent.connect('qq');
      });
      tearDown(() async {
        await agent.shutdown();
        agent.dispose();
      });
      Json tool(String name, Json args) => {
        'choices': [
          {
            'message': {
              'tool_calls': [
                {
                  'id': 'test-call',
                  'type': 'function',
                  'function': {
                    'name': 'yy-tts__$name',
                    'arguments': jsonEncode(args),
                  },
                },
              ],
            },
          },
        ],
      };
      Future<void> run(String name, [Json args = const {}]) async {
        model.handler = (n, _) async =>
            n == 1 ? tool(name, args) : fixture.answer('测试完成');
        transport.receive(id: 'yy-${received++}');
        await fixture.eventually(
          () => model.requests.length >= 2 && agent.busySessions.isEmpty,
        );
      }

      test('默认URL语音把编码后的TTS链接交给OneBot，不在本机请求TTS或排队', () async {
        expect(extension.config['delivery'], 'url');
        await agent.saveExtension(
          extension.copyWith(
            enabled: true,
            settings: {'character': '甜妹', 'speed': 0.9},
          ),
        );
        http.fail = true;
        http.metadataFail = true;
        const value = '这是 AI 的回复 & + 😀';
        await run('read_aloud', {'text': value});
        expect(http.requests, isEmpty);
        final sent = transport.sent.singleWhere(
          (s) => jsonEncode(s).contains('"record"'),
        );
        expect(sent['action'], 'send_group_msg');
        expect(sent['group_id'], 20002);
        final segment = object((sent['message'] as List).single);
        expect(segment['type'], 'record');
        final uri = Uri.parse(text(object(segment['data'])['file']));
        expect(uri.path, '/tts');
        expect(uri.queryParameters, {
          'character': '甜妹',
          'text': value,
          'speed': '0.9',
        });
        expect(jsonEncode(model.requests.last), contains('已通过适配器'));
      });
      test('URL语音拒绝本地地址，并在协议失败或没有消息ID时不报告成功', () async {
        for (final scenario in ['private', 'failed', 'no-id']) {
          model.requests.clear();
          transport.sent.clear();
          transport.failVoice = scenario == 'failed';
          transport.emptyVoiceId = scenario == 'no-id';
          await agent.saveExtension(
            extension.copyWith(
              enabled: true,
              settings: {
                if (scenario == 'private') 'apiBase': 'https://127.0.0.1',
              },
            ),
          );
          await run('read_aloud', {'text': '测试'});
          expect(http.requests, isEmpty);
          expect(jsonEncode(model.requests.last), isNot(contains('语音已发送。角色')));
          expect(
            jsonEncode(model.requests.last),
            contains(
              scenario == 'private'
                  ? '内网'
                  : scenario == 'failed'
                  ? '未返回语音回执'
                  : '未返回消息 ID',
            ),
          );
          expect(
            transport.sent.where((s) => jsonEncode(s).contains('"record"')),
            hasLength(scenario == 'no-id' ? 1 : 0),
          );
        }
      });
      test('默认直连仅请求tts一次，中文/空格/特殊符号正确编码且音色语速来自设置', () async {
        expect(extension.config['mode'], 'direct');
        expect(extension.config['character'], '甜妹');
        await agent.saveExtension(
          extension.copyWith(
            enabled: true,
            settings: {
              'character': '甜妹',
              'speed': 1.25,
              'apiBase': 'https://yy.jujiang.js.cn/tts',
              'delivery': 'download',
            },
          ),
        );
        http.metadataFail = true;
        const text = '你好 & name=谁？ + / 😀\n第二行';
        await run('read_aloud', {'text': text});
        expect(http.requests, hasLength(1));
        final request = http.requests.single.uri;
        expect(request.path, '/tts');
        expect(request.queryParameters, {
          'character': '甜妹',
          'text': text,
          'speed': '1.25',
        });
        expect(jsonEncode(model.requests.last), contains('语音已发送'));
        expect(jsonEncode(model.requests.last), isNot(contains('情感：')));
        expect(
          transport.sent.where((s) => jsonEncode(s).contains('base64://')),
          hasLength(1),
        );
      });
      test('直连JSON音频地址和302下载均能发送，不再走排队接口', () async {
        for (final json in [true, false]) {
          http.requests.clear();
          model.requests.clear();
          http.directJson = json;
          http.directRedirect = !json;
          await agent.saveExtension(
            extension.copyWith(
              enabled: true,
              settings: {'delivery': 'download'},
            ),
          );
          await run('read_aloud', {'text': '测试'});
          expect(http.requests.map((r) => r.uri.path), [
            '/tts',
            '/generated/voice.wav',
          ]);
          expect(jsonEncode(model.requests.last), contains('语音已发送'));
        }
      });
      test('直连503或重定向回合成端点均只提交一次，无Gradio自动回退', () async {
        for (final loop in [false, true]) {
          http.requests.clear();
          model.requests.clear();
          http.fail = !loop;
          http.directRedirect = loop;
          http.directLoop = loop;
          await agent.saveExtension(
            extension.copyWith(
              enabled: true,
              settings: {'delivery': 'download'},
            ),
          );
          await run('read_aloud', {'text': '测试'});
          expect(http.requests, hasLength(1));
          expect(
            jsonEncode(model.requests.last),
            contains(loop ? '未重复请求合成' : 'HTTP 503'),
          );
          expect(jsonEncode(transport.sent), isNot(contains('base64://')));
        }
      });
      test('直连返回HTML或QQ协议发送失败时如实返回失败', () async {
        for (final badAudio in [true, false]) {
          model.requests.clear();
          http.requests.clear();
          http.invalidAudio = badAudio;
          transport.failVoice = !badAudio;
          await agent.saveExtension(
            extension.copyWith(
              enabled: true,
              settings: {'delivery': 'download'},
            ),
          );
          await run('read_aloud', {'text': '测试'});
          expect(
            jsonEncode(model.requests.last),
            contains(badAudio ? '无法识别音频' : '未返回语音回执'),
          );
          expect(jsonEncode(model.requests.last), isNot(contains('语音已发送。角色')));
        }
      });
      test('直连参考音色和情感说明不依赖旧站点配置，不发送语音', () async {
        await agent.saveExtension(extension.copyWith(enabled: true));
        await run('list_voices', {'query': '甜妹'});
        expect(jsonEncode(model.requests.last), contains('随包音色参考列表'));
        model.requests.clear();
        await run('list_emotions');
        expect(jsonEncode(model.requests.last), contains('仅发送角色、正文和语速'));
        expect(http.requests, isEmpty);
        expect(jsonEncode(transport.sent), isNot(contains('base64://')));
      });
      test('17参数、无参考音频、SSE、WAV下载与真实协议回执，设置即时生效', () async {
        expect(extension.enabled, false);
        expect(extension.configSchema['character']['values'], hasLength(371));
        expect(http.requests, isEmpty, reason: '导入与启用检查不合成或联网');
        await agent.saveExtension(
          extension.copyWith(
            enabled: true,
            settings: {
              'mode': 'gradio',
              'character': '七七',
              'emotion': '开心',
              'speed': 1.25,
            },
          ),
        );
        await run('read_aloud', {'text': '你好，这是语音测试'});
        final data = http.submitted.single;
        expect(data, hasLength(17));
        expect(data.take(8).toList(), [
          '你好，这是语音测试',
          '七七',
          '开心',
          null,
          '',
          'auto',
          1.25,
          'auto',
        ]);
        final messages = transport.sent
            .where((s) => jsonEncode(s).contains('base64://'))
            .toList();
        expect(messages, hasLength(1));
        expect(jsonEncode(model.requests.last), contains('语音已发送'));
      });
      test('查音色和查情感不是发语音，不会被语音回执保护误报失败', () async {
        await run('list_voices', {'query': '七七'});
        expect(jsonEncode(model.requests.last), contains('七七'));
        expect(jsonEncode(model.requests.last), isNot(contains('没有取得发送回执')));
        expect(http.submitted, isEmpty);
        model.requests.clear();
        await run('list_emotions');
        expect(jsonEncode(model.requests.last), contains('开心'));
        expect(jsonEncode(transport.sent), isNot(contains('base64://')));
      });
      test('默认站点元数据不可达时按已验证协议降级，记录快照并只提交一次合成', () async {
        http.metadataFail = true;
        await run('read_aloud', {'text': '测试'});
        expect(
          http.requests.where((r) => r.uri.path == '/config'),
          hasLength(2),
        );
        expect(http.submitted, hasLength(1));
        expect(
          agent.logs.any((l) => text(l['message']).contains('随包保存')),
          true,
        );
        expect(jsonEncode(model.requests.last), contains('语音已发送'));
      });
      test('合成成功但协议拒绝语音时不向模型谎报已发送', () async {
        transport.failVoice = true;
        await run('read_aloud', {'text': '测试'});
        expect(jsonEncode(model.requests.last), contains('未返回语音回执'));
        expect(jsonEncode(model.requests.last), isNot(contains('语音已发送。角色')));
        expect(jsonEncode(transport.sent), isNot(contains('base64://')));
      });
      test('服务503不重复提交，不伪造成功', () async {
        http.fail = true;
        await run('read_aloud', {'text': '测试'});
        expect(http.submitted, hasLength(1));
        expect(jsonEncode(model.requests.last), contains('HTTP 503'));
        expect(jsonEncode(transport.sent), isNot(contains('base64://')));
      });
      test('未声明Gradio4队列协议的兼容服务使用call接口，不重复提交', () async {
        http.useQueue = false;
        await run('read_aloud', {'text': '测试'});
        expect(http.submitted, hasLength(1));
        expect(
          http.requests.where((r) => r.uri.path == '/queue/join'),
          isEmpty,
        );
        expect(jsonEncode(model.requests.last), contains('语音已发送'));
      });
      test('缺少完成事件不会下载或发送伪音频', () async {
        http.incomplete = true;
        await run('read_aloud', {'text': '测试'});
        expect(jsonEncode(model.requests.last), contains('未收到语音服务的完成事件'));
        expect(
          http.requests.where((r) => r.uri.path.startsWith('/file=')),
          isEmpty,
        );
        expect(jsonEncode(transport.sent), isNot(contains('base64://')));
      });
      test('下载到HTML时音频校验拦截，不发生语音发送', () async {
        http.invalidAudio = true;
        await run('read_aloud', {'text': '测试'});
        expect(jsonEncode(model.requests.last), contains('无法识别音频'));
        expect(jsonEncode(transport.sent), isNot(contains('base64://')));
      });
    },
    skip: Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
        ? '需要测试JavaScript引擎'
        : false,
  );
}
