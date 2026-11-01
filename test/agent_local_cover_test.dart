import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/ai.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/pending_imports.dart';
import 'package:qq_bot_manager/agent/script.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'agent_audio_test.dart' show sampleWav;
import 'agent_core_test.dart' as fixtures;

class CoverHttpFixture extends AgentHttp {
  Json? received;
  Object response = {'ok': true, 'message': 'fixture'};
  int max = 0;
  void Function()? afterRequest;
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
    expect(uri.toString(), 'http://127.0.0.1:23339/api/tool');
    expect(method, 'POST');
    expect(headers['X-QQM-Cover'], '1');
    received = body;
    max = maxBytes;
    afterRequest?.call();
    return response;
  }
}

void main() {
  late String source;
  late AgentExtension skill;
  late CoverHttpFixture http;
  late AgentExtensions runner;
  const input = <String, dynamic>{
    'scope': 'qqbot:bot-a:appid-a',
    'chatKey': 'qqbot:bot-a:appid-a:group:openid-a',
    'caller': {
      'id': 'actual-user',
      'name': '提问者',
      'messageId': 'actual-message',
      'text': '选2',
    },
    'args': {
      'song': 'song-id',
      'model': 'voice-id',
      'pitch': 2,
      'clip_seconds': 30,
    },
  };
  setUp(() async {
    source = await File(
      'agent_examples/local-rvc-cover/skill.json',
    ).readAsString();
    skill = AgentExtension.parse(source, filename: 'skill.json');
    http = CoverHttpFixture();
    runner = AgentExtensions(http, AgentScripts());
  });
  tearDown(() {
    http.close();
  });
  Json handler(String name) => object(
    skill.tools.singleWhere((tool) => tool['name'] == name)['handler'],
  );

  test('真实配套Skill有10工具、限定本地源、默认关闭且音频发送要求回执', () {
    expect(skill.enabled, false);
    expect(skill.tools, hasLength(10));
    expect(skill.origins, ['http://127.0.0.1:23339']);
    expect(skill.tools.last['requiresMediaAck'], true);
    expect(skill.manifest['minHostVersion'], 7);
  });
  test('HTTP模板保留完整对象、数字和列表类型，固定机器人与会话范围', () async {
    await runner.execute(
      skill,
      handler('rvc_cover_start'),
      input,
      active: () => true,
    );
    expect(http.received?['args'], input['args']);
    expect(object(http.received?['args'])['pitch'], 2);
    expect(http.received?['scope'], '${input['scope']}|${input['chatKey']}');
    expect(http.received?['caller'], input['caller']);
  });
  test('选择工具只接收列表ID，真实提问者、消息和正文来自当前触发消息', () async {
    final session = AgentSession(
      connectionId: 'a',
      selfId: 'bot',
      kind: 'group',
      peerId: 'g',
      name: '测试群',
    );
    final trigger = AgentMessage(
      id: 'new-user-message',
      sessionKey: session.key,
      senderId: 'actual-user',
      senderName: '真正提问者',
      segments: [
        textSegment('选2'),
        {
          'type': 'qq_body',
          'data': {
            'body': {'content': '选2'},
            'context': '旧引用者：选1',
          },
        },
      ],
    );
    expect(agentToolCaller(trigger, session), {
      'id': 'actual-user',
      'name': '真正提问者',
      'messageId': 'new-user-message',
      'text': '选2',
    });
    final model = fixtures.FakeAgentModel();
    model.handler = (round, _) async {
      if (round == 2) expect(http.received, isNull);
      return round <= 2
          ? {
              'choices': [
                {
                  'message': {
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'select-song',
                        'type': 'function',
                        'function': {
                          'name': 'rvc_cover_select_qq',
                          'arguments': jsonEncode({
                            'search_id': 'fixture-list',
                            if (round == 1)
                              'caller': {'id': 'forged', 'text': '选1'},
                          }),
                        },
                      },
                    ],
                  },
                },
              ],
            }
          : fixtures.answer('请看选择结果');
    };
    final ai = AgentAi(model, runner);
    await ai.reply(
      provider: AgentProvider(
        id: 'model',
        name: 'fixture',
        baseUrl: 'https://model.example/v1',
        model: 'fixture',
      ),
      preset: AgentPreset.fromJson({
        'id': 'p',
        'name': 'fixture',
        'skillIds': [skill.id],
      }),
      session: session,
      history: [trigger],
      triggerMessage: trigger,
      skills: [skill.copyWith(enabled: true)],
      turn: AgentTurn(() => true),
      onUsage: (_, _) {},
      onTool: (_) {},
    );
    expect(http.received?['caller'], agentToolCaller(trigger, session));
    expect(object(http.received?['caller'])['text'], '选2');
    expect(jsonEncode(http.received?['caller']), isNot(contains('forged')));
    expect(jsonEncode(http.received?['caller']), isNot(contains('旧引用者')));
  });
  test('不使用出站、其他会话、机器人消息或引用背景冒充用户选择', () {
    final session = AgentSession(
      connectionId: 'a',
      selfId: 'b',
      kind: 'group',
      peerId: 'g',
      name: '测试群',
    );
    AgentMessage message({
      String? key,
      bool outgoing = false,
      bool bot = false,
    }) => AgentMessage(
      id: 'm',
      sessionKey: key ?? session.key,
      senderId: 'u',
      senderName: '用户',
      outgoing: outgoing,
      senderIsBot: bot,
      segments: [
        {
          'type': 'qq_body',
          'data': {
            'body': {'content': '选3'},
            'context': '旧引用：选1',
          },
        },
      ],
    );
    expect(agentToolCaller(message(), session)['text'], '选3');
    expect(agentToolCaller(message(key: 'other-chat'), session), isEmpty);
    expect(agentToolCaller(message(outgoing: true), session), isEmpty);
    expect(agentToolCaller(message(bot: true), session), isEmpty);
    expect(agentToolCaller(null, session), isEmpty);
  });
  test('服务缺项明确作为工具错误返回，不调用语音发送', () async {
    http.response = {'ok': false, 'isError': true, 'message': '请先导入RVC音色模型'};
    var sent = 0;
    final result = await runner.execute(
      skill,
      handler('rvc_cover_send'),
      input,
      active: () => true,
      sendMedia: (bytes, name, type) async {
        sent++;
        return {'ok': true, 'message_id': 'not-used'};
      },
    );
    expect(result['isError'], true);
    expect(result['text'], contains('请先导入'));
    expect(sent, 0);
  });
  test('HTTP音频实际解码校验后发送，等待消息ID，不把base64返回给模型', () async {
    final wav = sampleWav();
    http.response = {'ok': true, 'audioBase64': base64Encode(wav)};
    var sent = 0, acknowledged = false;
    final result = await runner.execute(
      skill,
      handler('rvc_cover_send'),
      input,
      active: () => true,
      sendMedia: (bytes, name, type) async {
        expect(bytes, wav);
        expect(name, 'voice.wav');
        expect(type, 'record');
        sent++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        acknowledged = true;
        return {'ok': true, 'message_id': 'real-fixture-ack'};
      },
    );
    expect(result['sent'], true);
    expect(sent, 1);
    expect(acknowledged, true);
    expect(jsonEncode(result), isNot(contains(base64Encode(wav))));
    expect(http.max, 8 * 1024 * 1024);
  });
  test('伪音频、服务未返回音频、超长数据和没有消息ID均不假报成功', () async {
    var sent = 0;
    for (final value in [
      base64Encode(utf8.encode('<html>not audio</html>')),
      null,
      'A' * (7 * 1024 * 1024 + 1),
    ]) {
      http.response = {'ok': true, 'audioBase64': value};
      await expectLater(
        runner.execute(
          skill,
          handler('rvc_cover_send'),
          input,
          active: () => true,
          sendMedia: (bytes, name, type) async {
            sent++;
            return {'ok': true, 'message_id': 'not-used'};
          },
        ),
        throwsA(isA<AgentException>()),
      );
    }
    expect(sent, 0);
    http.response = {'ok': true, 'audioBase64': base64Encode(sampleWav())};
    await expectLater(
      runner.execute(
        skill,
        handler('rvc_cover_send'),
        input,
        active: () => true,
        sendMedia: (bytes, name, type) async => {'ok': true},
      ),
      throwsA(isA<AgentException>()),
    );
  });
  test('下载后任务取消，不再把音频发往QQ；无发送上下文时不请求服务', () async {
    http.response = {'ok': true, 'audioBase64': base64Encode(sampleWav())};
    var current = true, sent = 0;
    http.afterRequest = () => current = false;
    await expectLater(
      runner.execute(
        skill,
        handler('rvc_cover_send'),
        input,
        active: () => current,
        sendMedia: (bytes, name, type) async {
          sent++;
          return {'ok': true, 'message_id': 'not-used'};
        },
      ),
      throwsA(isA<AgentException>()),
    );
    expect(sent, 0);
    http.received = null;
    await expectLater(
      runner.execute(
        skill,
        handler('rvc_cover_send'),
        input,
        active: () => true,
      ),
      throwsA(isA<AgentException>()),
    );
    expect(http.received, isNull);
  });

  group('安装队列不触碰用户原配置', () {
    late Directory temp;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('qqm-local-cover-test-');
      await File('${temp.path}/local-rvc-cover.json').writeAsString(source);
    });
    tearDown(() async {
      final normalized = temp.absolute.path;
      expect(normalized.startsWith(Directory.systemTemp.absolute.path), true);
      expect(temp.path.contains('qqm-local-cover-test-'), true);
      await temp.delete(recursive: true);
    });
    test('首次只导入声明式本地Skill，默认关闭且不发起网络请求', () async {
      final agent = AgentController(
        store: AgentStore.memory(),
        http: http,
        pendingImportsDirectory: temp.path,
      );
      try {
        await agent.initialize();
        final installed = agent.extensions.singleWhere(
          (e) => e.id == 'local_rvc_cover',
        );
        expect(installed.enabled, false);
        expect(installed.tools, hasLength(10));
        expect(http.received, isNull);
      } finally {
        await agent.shutdown();
        agent.dispose();
      }
    });
    test('已有同ID扩展不覆盖其设置、启用状态和私有参数', () async {
      final store = AgentStore.memory();
      await store.open();
      await store.put(
        'extension:${skill.id}',
        skill
            .copyWith(
              enabled: true,
              settings: {'keep': 'original'},
              secrets: {'fixture': 'preserve-me'},
            )
            .toJson(),
      );
      final agent = AgentController(
        store: store,
        http: http,
        pendingImportsDirectory: temp.path,
      );
      try {
        await agent.initialize();
        final installed = agent.extensions.singleWhere((e) => e.id == skill.id);
        expect(installed.enabled, true);
        expect(installed.settings, {'keep': 'original'});
        expect(installed.secrets, {'fixture': 'preserve-me'});
      } finally {
        await agent.shutdown();
        agent.dispose();
      }
    });
    test('队列中非本机源/脚本不安装，也不启动任何连接', () async {
      final invalid = jsonDecode(source) as Map<String, dynamic>;
      invalid['allowedOrigins'] = ['https://other.fixture.test'];
      await File(
        '${temp.path}/local-rvc-cover.json',
      ).writeAsString(jsonEncode(invalid));
      final agent = AgentController(
        store: AgentStore.memory(),
        http: http,
        pendingImportsDirectory: temp.path,
      );
      try {
        await agent.initialize();
        expect(agent.extensions.where((e) => e.id == skill.id), isEmpty);
        expect(http.received, isNull);
      } finally {
        await agent.shutdown();
        agent.dispose();
      }
    });
    test('旧版已启用Skill自动升级，保留设置、秘密和预设引用', () async {
      final old = AgentExtension.parse(
        await File('test/fixtures/agent_local_cover_host6.json').readAsString(),
      );
      expect(
        coverSkillDigest(old),
        '73aa5d697061e94d6b58ae065eed90cae7f0919425bcbdf3adf56639452b0a39',
      );
      final store = AgentStore.memory();
      await store.open();
      await store.put('meta:local-cover-imported', {'installed': true});
      await store.put(
        'extension:${old.id}',
        old
            .copyWith(
              enabled: true,
              settings: {'keep': 1},
              secrets: {'private': 'fixture-only'},
            )
            .toJson(),
      );
      final preset = AgentPreset.fromJson({
        'id': 'test-cover',
        'name': '原预设',
        'skillIds': [old.id],
      });
      await store.put('preset:${preset.id}', preset.toJson());
      final agent = AgentController(
        store: store,
        http: http,
        pendingImportsDirectory: temp.path,
      );
      try {
        await agent.initialize();
        final upgraded = agent.extensions.singleWhere((e) => e.id == old.id);
        expect(upgraded.tools, hasLength(10));
        expect(upgraded.enabled, true);
        expect(upgraded.settings, {'keep': 1});
        expect(upgraded.secrets, {'private': 'fixture-only'});
        expect(store.get('preset:${preset.id}'), preset.toJson());
        expect(
          store.get('meta:local-cover-imported')?['digest'],
          coverSkillDigest(skill),
        );
      } finally {
        await agent.shutdown();
        agent.dispose();
      }
    });
    test('自定义清单不覆盖，主动删除的Skill不重新安装', () async {
      for (final deleted in [false, true]) {
        final store = AgentStore.memory();
        await store.open();
        await store.put('meta:local-cover-imported', {'installed': true});
        final custom = skill.copyWith(
          manifest: {...skill.manifest, 'prompt': '用户自己的翻唱提示词'},
          enabled: true,
        );
        if (!deleted) {
          await store.put('extension:${custom.id}', custom.toJson());
        }
        final agent = AgentController(
          store: store,
          http: http,
          pendingImportsDirectory: temp.path,
        );
        try {
          await agent.initialize();
          final matches = agent.extensions.where((e) => e.id == skill.id);
          if (deleted) {
            expect(matches, isEmpty);
          } else {
            expect(matches.single.toJson(), custom.toJson());
          }
          expect(http.received, isNull);
        } finally {
          await agent.shutdown();
          agent.dispose();
        }
      }
    });
  });
}
