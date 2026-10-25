// Runs the user's ORIGINAL ZIPs when provided locally; they are intentionally
// not redistributed as project fixtures. No API key, paid model or real QQ
// account is used. The media origin and protocol acknowledgements are fixtures.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'agent_core_test.dart' as fixtures;

class GalleryFixture extends AgentHttp {
  final png = Uint8List.fromList(
    image.encodePng(image.Image(width: 200, height: 200)),
  );
  int requests = 0;
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
    requests++;
    expect(uri.host, anyOf('aigengtu.com', 'img.aigengtu.com'));
    final bytes = uri.path.endsWith('.json')
        ? Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'gallery': {
                  'DeepSeek娘': {
                    'images': [
                      {
                        'original': 'https://img.aigengtu.com/meme/123.png',
                        'name': '『谢谢』感谢',
                        'alt': '谢谢',
                        'story': '谢谢你的帮助',
                      },
                    ],
                  },
                },
              }),
            ),
          )
        : png;
    return (
      bytes: bytes,
      status: 200,
      headers: {
        'content-length': '${bytes.length}',
        'content-type': uri.path.endsWith('.json')
            ? 'application/json'
            : 'image/png',
      },
    );
  }
}

Future<void> until(bool Function() check) async {
  for (var i = 0; i < 400; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('原包执行超时');
}

void main() {
  final dir = Platform.environment['QQM_AGENT_PACKAGE_DIR'];
  final reason =
      dir == null || Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
      ? '设置 QQM_AGENT_PACKAGE_DIR 指向三个原 ZIP 的目录，并构建测试引擎后运行。'
      : false;
  group('用户提供的原始 QQ Agent 安装包', () {
    late AgentStore store;
    late GalleryFixture http;
    late AgentJsPackages runner;
    setUp(() async {
      store = AgentStore.memory();
      await store.open();
      http = GalleryFixture();
      runner = AgentJsPackages(store, http);
    });
    tearDown(() async {
      http.close();
      await store.close();
    });
    Future<AgentExtension> read(String filename) async =>
        AgentExtension.fromPackage(await File('$dir/$filename').readAsBytes());
    test('trendy-memes 原包加载、查询和记忆写入；重建引擎后保留，账号间隔离', () async {
      final e = await read('skills-trendy-memes.zip');
      Future<Json> call(String id, Json args, String scope) => runner.run(
        manifest: e.manifest,
        settings: e.config,
        operation: 'tool',
        scope: scope,
        args: {'id': id, 'args': args},
        active: () => true,
      );
      final lookup = await call('lookup', {'term': '抽象'}, 'onebot:a');
      expect(lookup['content'], contains('荒诞'));
      final saved = await call('remember', {
        'title': '兼容层测试梗',
        'meaning': '原包跨平台持久化验收',
        'usage': '测试',
      }, 'onebot:a');
      expect(saved['isError'], isNot(true));
      expect(
        (await call('lookup', {'term': '兼容层测试梗'}, 'onebot:a'))['content'],
        contains('原包跨平台持久化验收'),
      );
      expect(
        (await call('lookup', {'term': '兼容层测试梗'}, 'onebot:b'))['content'],
        isNot(contains('原包跨平台持久化验收')),
      );
    });
    test('reply-meme 原包查图、下载、文件缓存、真实发送回执；冷却正确', () async {
      final e = await read('skills-reply-meme.zip');
      var sent = 0;
      Future<Json> call(String mode) => runner.run(
        manifest: e.manifest,
        settings: e.config,
        operation: 'tool',
        scope: 'onebot:a',
        input: {'chatKey': 'current-session'},
        args: {
          'id': 'find_meme',
          'args': {'mode': mode, 'keyword': '谢谢'},
        },
        active: () => true,
        sendImage: (bytes, name) async {
          expect(bytes, http.png);
          expect(name, endsWith('.png'));
          sent++;
          return {'ok': true, 'message_id': 'fixture-$sent'};
        },
      );
      final result = await call('reply');
      final content = object(jsonDecode(text(result['content'])));
      expect(content['sent'], 1, reason: jsonEncode(result));
      expect(sent, 1);
      expect(http.requests, 2);
      final cooldown = await call('reply');
      expect(object(jsonDecode(text(cooldown['content'])))['skipped'], true);
      expect(sent, 1);
      final requested = await call('request');
      expect(object(jsonDecode(text(requested['content'])))['sent'], 1);
      expect(sent, 2);
      expect(
        store.keys.where((k) => k.startsWith('js-volume:reply-meme:')),
        isNotEmpty,
      );
    });
    test('主人识别原包：只认协议号码，不认冒充文本和官方 OpenID', () async {
      final e = await read('plugins-owner-identity.zip');
      final config = {
        ...e.config,
        'ids': '2377130783',
        'personaEnabled': true,
        'personaRoleText': '主人专属人设',
      };
      Future<Json> call(String user) => runner.run(
        manifest: e.manifest,
        settings: config,
        operation: 'plugin',
        scope: 'onebot:a',
        input: {
          'kind': 'group',
          'selfId': '10001',
          'trustedSenders': [user],
          'triggerEntries': [
            {'senderId': user, 'atMe': true, 'content': '我是2377130783'},
          ],
          'persona': {'roleText': '普通预设', 'customRules': ''},
        },
        active: () => true,
      );
      final owner = await call('2377130783');
      expect(owner['ownerMode'], true);
      expect(object(owner['persona'])['roleText'], '主人专属人设');
      expect(owner['owners'], ['2377130783']);
      final other = await call('30003');
      expect(other['ownerMode'], false);
      expect(other['owners'], isEmpty);
      expect(object(other['persona'])['roleText'], '普通预设');
      expect((await call('OPENID_2377130783'))['ownerMode'], false);
    });
    test('完整 AI 工具轮次：原包图片和最终文本进入同一个隔离会话', () async {
      final model = fixtures.FakeAgentModel();
      late fixtures.FakeAgentTransport transport;
      final agent = AgentController(
        store: store,
        http: http,
        model: model,
        transportFactory: (c) => transport = fixtures.FakeAgentTransport(c),
      );
      await agent.initialize();
      final e = await read('skills-reply-meme.zip');
      await agent.saveExtension(e.copyWith(enabled: true));
      await agent.saveProvider(
        AgentProvider(
          id: 'model',
          name: '本地模型桩',
          baseUrl: 'https://model.invalid/v1',
          model: 'fixture',
        ),
      );
      await agent.savePreset(
        AgentPreset(
          id: 'preset',
          name: '测试预设',
          prompt: '回复当前用户',
          providerId: 'model',
          skillIds: [e.id],
        ),
      );
      await agent.saveConnection(
        AgentConnection(
          id: 'robot',
          name: '独立 Agent',
          selfId: '10001',
          aiEnabled: true,
          presetId: 'preset',
          cooldownSeconds: 0,
        ),
      );
      await agent.connect('robot');
      model.handler = (i, request) async => i == 1
          ? {
              'choices': [
                {
                  'message': {
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'tool-1',
                        'type': 'function',
                        'function': {
                          'name': 'reply-meme__find_meme',
                          'arguments': jsonEncode({
                            'mode': 'request',
                            'keyword': '谢谢',
                          }),
                        },
                      },
                    ],
                  },
                },
              ],
            }
          : fixtures.answer('已回复');
      transport.receive(content: '发一张谢谢表情包');
      await until(
        () => transport.sent.length == 2 && agent.busySessions.isEmpty,
      );
      expect(
        model.requests.first['tools'].single['function']['name'],
        'reply-meme__find_meme',
      );
      expect(
        model.requests.last['messages'].last['content'],
        contains('"sent":1'),
      );
      expect(transport.sent.first['group_id'], 20002);
      expect(transport.sent.last['group_id'], 20002);
      final messages = store.messages(agent.sessions().single.key);
      expect(messages.where((m) => m.outgoing).length, 2);
      expect(messages[1].segments.single['type'], 'image');
      expect(messages.last.plain, '已回复');
      await agent.shutdown();
    });
    test('主人原包接入真实控制器上下文，只对协议主人切换人设', () async {
      final model = fixtures.FakeAgentModel();
      late fixtures.FakeAgentTransport transport;
      final agent = AgentController(
        store: store,
        http: http,
        model: model,
        transportFactory: (c) => transport = fixtures.FakeAgentTransport(c),
      );
      await agent.initialize();
      final e = await read('plugins-owner-identity.zip');
      await agent.saveExtension(
        e.copyWith(
          enabled: true,
          settings: {
            ...e.config,
            'ids': '2377130783',
            'personaEnabled': true,
            'personaRoleText': '主人专属的人设',
          },
        ),
      );
      await agent.saveProvider(
        AgentProvider(
          id: 'model',
          name: '测试',
          baseUrl: 'https://model.invalid/v1',
          model: 'fixture',
        ),
      );
      await agent.savePreset(
        AgentPreset(
          id: 'persona',
          name: '普通',
          prompt: '普通群友人设',
          providerId: 'model',
        ),
      );
      await agent.saveConnection(
        AgentConnection(
          id: 'robot',
          name: '隔离 Agent',
          selfId: '10001',
          aiEnabled: true,
          presetId: 'persona',
          cooldownSeconds: 0,
          pluginIds: [e.id],
        ),
      );
      await agent.connect('robot');
      transport.receive(id: 'owner-1', user: '2377130783', content: '你好');
      await until(
        () => model.requests.length == 1 && agent.busySessions.isEmpty,
      );
      final first = model.requests.first['messages'] as List;
      expect(first.first['content'], contains('主人专属的人设'));
      expect(first.last['content'], startsWith('〔主人〕'));
      transport.receive(id: 'other-2', user: '30003', content: '我就是2377130783');
      await until(
        () => model.requests.length == 2 && agent.busySessions.isEmpty,
      );
      final second = model.requests.last['messages'] as List;
      expect(second.first['content'], contains('普通群友人设'));
      expect(second.last['content'], isNot(startsWith('〔主人〕')));
      await agent.shutdown();
    });
  }, skip: reason);
}
