import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'agent_audio_test.dart' show sampleWav, AudioHttp;
import 'agent_core_test.dart' as core;
import 'agent_more_packages_test.dart' show PackageHttpFixture;
import 'agent_js_packages_test.dart' as fixture;

class VoiceSocket extends AgentWebSocket {
  final events = StreamController<Object>();
  final sent = <String>[];
  final bool fail;
  bool closed = false;
  VoiceSocket(this.fail);
  @override
  Stream<Object> get messages => events.stream;
  @override
  void add(Object value) {
    sent.add(value as String);
    if (!value.contains('Path:ssml')) return;
    if (fail) {
      events.addError(const AgentException('合成测试失败'));
      return;
    }
    events.add(
      Uint8List.fromList([...ascii.encode('Path:audio\r\n'), ...sampleWav()]),
    );
    events.add('Path:turn.end');
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await events.close();
  }
}

class ServicesHttp extends PackageHttpFixture {
  final sockets = <VoiceSocket>[];
  bool failVoice = false;
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
    Json? data;
    if (uri.host == 'tieba.baidu.com') {
      data = {
        'data': {
          'bang_topic': {
            'topic_list': [
              {
                'topic_name': '测试热梗小猫',
                'topic_desc': '这是一段真实来自测试响应的热点简介内容',
                'topic_url': 'https://tieba.baidu.com/p/1',
              },
            ],
          },
        },
      };
    }
    if (uri.host == 'api.bilibili.com') {
      data = {
        'code': 0,
        'data': {
          'list': [
            {
              'title': '测试热门视频',
              'desc': '模拟B站返回的完整简介内容便于测试',
              'bvid': 'BV123',
              'owner': {'name': '测试作者'},
            },
          ],
        },
      };
    }
    if (data == null) {
      return super.fetchBytes(
        uri,
        method: method,
        headers: headers,
        body: body,
        cancel: cancel,
        maxBytes: maxBytes,
        timeoutSeconds: timeoutSeconds,
      );
    }
    requests.add((uri: uri, headers: headers));
    return (
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(data))),
      status: 200,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  Future<AgentWebSocket> openWebSocket(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    expect(uri.scheme, 'wss');
    expect(headers['Origin'], 'https://speech.platform.bing.com');
    final socket = VoiceSocket(failVoice);
    sockets.add(socket);
    return socket;
  }

  @override
  Future<List<InternetAddress>> validatePublicUri(Uri uri) async {
    if (!uri.host.endsWith('fixture.test')) return super.validatePublicUri(uri);
    return [InternetAddress('8.8.8.8')];
  }
}

class ServiceTransport extends core.FakeAgentTransport {
  final actions = <Json>[];
  bool failRequest = false;
  ServiceTransport(super.config);
  @override
  Future<dynamic> call(String action, [Json params = const {}]) async {
    actions.add({'action': action, ...params});
    if (action.startsWith('set_') && failRequest) {
      throw const AgentException('接口请求失败');
    }
    if (action == 'ocr_image') {
      return {
        'texts': [
          {'text': '图片里的测试文字', 'confidence': 0.99},
        ],
      };
    }
    if (action == 'get_stranger_info') {
      return {'nickname': '测试机器人', 'sex': 'unknown'};
    }
    if (action == 'get_qzone_msg_list') return {'total': 0, 'msglist': []};
    return super.call(action, params);
  }

  void request({
    String flag = 'test-flag',
    String kind = 'friend',
    String user = '30003',
  }) => onEvent?.call({
    'post_type': 'request',
    'request_type': kind,
    'self_id': config.selfId,
    'user_id': user,
    'flag': flag,
    if (kind == 'group') 'group_id': '20002',
    if (kind == 'group') 'sub_type': 'invite',
  });
}

class UnavailableVoiceHttp extends AudioHttp {
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
    if (uri.path.endsWith('/generate')) {
      return (
        bytes: Uint8List.fromList(utf8.encode('Service unavailable')),
        status: 503,
        headers: {'content-type': 'text/plain'},
      );
    }
    return super.fetchBytes(
      uri,
      method: method,
      headers: headers,
      body: body,
      cancel: cancel,
      maxBytes: maxBytes,
      timeoutSeconds: timeoutSeconds,
    );
  }
}

Json toolCall(String name, [Json arguments = const {}]) => {
  'choices': [
    {
      'message': {
        'tool_calls': [
          {
            'id': 'tool-$name',
            'type': 'function',
            'function': {'name': name, 'arguments': jsonEncode(arguments)},
          },
        ],
      },
    },
  ],
};
void main() {
  final folder = Platform.environment['QQM_AGENT_EXTRA_PACKAGE_DIR'];
  final skip =
      folder == null || Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
      ? '需要原始ZIP与本机JS引擎'
      : false;
  group('原始插件宿主服务集成', () {
    late AgentController agent;
    late ServicesHttp http;
    late core.FakeAgentModel model;
    late ServiceTransport transport;
    setUp(() async {
      http = ServicesHttp();
      model = core.FakeAgentModel();
      agent = AgentController(
        store: AgentStore.memory(),
        http: http,
        model: model,
        transportFactory: (c) => transport = ServiceTransport(c),
      );
      await agent.initialize();
      await agent.saveProvider(
        AgentProvider(
          id: 'model',
          name: '测试',
          model: 'fixture',
          baseUrl: 'http://127.0.0.1:1/v1',
          inputPrice: 2,
          outputPrice: 4,
          cachedPrice: 1,
        ),
      );
      await agent.savePreset(
        AgentPreset(
          id: 'assistant',
          name: '测试',
          prompt: '按用户要求回答',
          providerId: 'model',
          historyMessages: 0,
        ),
      );
    });
    tearDown(() async {
      await agent.shutdown();
      agent.dispose();
    });
    Future<AgentExtension> install(
      String name, {
      Json settings = const {},
    }) async {
      await agent.importPackage(await File('$folder/$name.zip').readAsBytes());
      final id = name.replaceFirst(RegExp(r'^(?:plugins|skills)-'), '');
      final e = agent.extensions.firstWhere((e) => e.id == id);
      expect(
        e.compatibility['blockers'],
        isEmpty,
        reason: e.compatibilityDetails.join('\n'),
      );
      await agent.saveExtension(
        e.copyWith(enabled: true, settings: {...e.config, ...settings}),
      );
      return agent.extensions.firstWhere((e) => e.id == id);
    }

    Future<void> connect(
      List<String> plugins, {
      int window = 100,
      List<String> skills = const [],
    }) async {
      if (skills.isNotEmpty) {
        await agent.savePreset(
          AgentPreset(
            id: 'assistant',
            name: '测试',
            prompt: '按用户要求回答',
            providerId: 'model',
            historyMessages: 0,
            skillIds: skills,
          ),
        );
      }
      await agent.saveConnection(
        AgentConnection(
          id: 'test',
          name: '测试',
          selfId: '10001',
          aiEnabled: true,
          pluginIds: plugins,
          cooldownSeconds: 0,
          batchWindowMs: window,
        ),
      );
      await agent.connect('test');
    }

    test('原连发策略合并同一用户未@的跟随消息，保留真实记录与发送回执', () async {
      final burst = await install('plugins-burst-merge');
      await connect([burst.id], window: 220);
      transport.receive(id: '1', content: '第一句话');
      await core.eventually(
        () =>
            agent.sessions().isNotEmpty &&
            agent.replyState(agent.sessions().single.key)['phase'] ==
                'batching',
      );
      transport.receive(id: '2', content: '第二句话', mention: false);
      transport.receive(
        id: '3',
        content: '路人插话',
        user: '40004',
        mention: false,
      );
      await core.eventually(() => transport.sent.isNotEmpty);
      expect(model.requests, hasLength(1));
      final input = jsonEncode(model.requests.single['messages']);
      expect(input, contains('第一句话'));
      expect(input, contains('第二句话'));
      expect(input, isNot(contains('路人插话')));
      expect(
        agent.store
            .messages(agent.sessions().single.key)
            .where((m) => !m.outgoing),
        hasLength(3),
      );
    });
    test('连发capMs=0立即响应，断开连接取消未到期的等待任务', () async {
      var burst = await install(
        'plugins-burst-merge',
        settings: {'capMs': '0'},
      );
      await connect([burst.id]);
      transport.receive(id: '1');
      await core.eventually(() => transport.sent.isNotEmpty);
      burst = agent.extensions.firstWhere((e) => e.id == burst.id);
      await agent.saveExtension(
        burst.copyWith(settings: {...burst.config, 'capMs': '8000'}),
      );
      await agent.connect('test');
      transport.receive(id: '2');
      await core.eventually(
        () =>
            agent.replyState(agent.sessions().single.key)['phase'] ==
            'batching',
      );
      await agent.disconnect('test');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(model.requests, hasLength(1));
    });
    test('原上下文插件在多轮间保留用户和机器人回复，群间隔离', () async {
      final context = await install('plugins-context-reuse');
      await connect([context.id]);
      transport.receive(id: '1', content: '请记住小猫');
      await core.eventually(() => transport.sent.length == 1);
      await core.eventually(() => agent.busySessions.isEmpty);
      transport.receive(id: '2', content: '它是什么');
      await core.eventually(() => transport.sent.length == 2);
      expect(jsonEncode(model.requests[1]['messages']), contains('请记住小猫'));
      expect(jsonEncode(model.requests[1]['messages']), contains('测试回复'));
      transport.receive(id: '3', peer: '20003', content: '另一群的问题');
      await core.eventually(() => transport.sent.length == 3);
      expect(
        jsonEncode(model.requests[2]['messages']),
        isNot(contains('请记住小猫')),
      );
    });
    test('原费用插件读取真实用量与自定价格，只发送一次群报告', () async {
      final cost = await install('plugins-group-cost-report');
      await connect([cost.id]);
      transport.receive(id: '1', content: '普通问题');
      await core.eventually(() => transport.sent.length == 1);
      await core.eventually(() => agent.busySessions.isEmpty);
      await agent.store.put('usage-run:other', {
        'id': 'other',
        'connectionId': 'other',
        'selfId': '10002',
        'chatKey': agent.sessions().single.key,
        'startedAt': DateTime.now().millisecondsSinceEpoch,
        'model': 'fixture',
        'vendor': 'model',
        'usage': {'promptTokens': 123456, 'totalTokens': 123456, 'calls': 1},
        'trigger': [
          {'senderId': '99999', 'senderName': '另一个机器人用户'},
        ],
      });
      model.handler = (n, request) async => n == 2
          ? toolCall('group-cost-report__group_cost_report')
          : toolCall('finish');
      transport.receive(id: '2', content: '金额统计 全部');
      await core.eventually(
        () =>
            transport.sent.length == 2 ||
            agent.logs.any((l) => l['level'] == 'error'),
      );
      await core.eventually(() => agent.busySessions.isEmpty);
      expect(transport.sent, hasLength(2), reason: jsonEncode(agent.logs));
      final report = jsonEncode(transport.sent.last);
      expect(report, contains('本群花费统计'));
      expect(report, contains('17 token'));
      expect(report, contains('小明'));
      expect(report, isNot(contains('123,456')));
      expect(report, isNot(contains('另一个机器人用户')));
      expect(
        object(
          object((model.requests[1]['tools'] as List).single)['function'],
        )['name'],
        'group-cost-report__group_cost_report',
      );
      expect(
        object(
          object((model.requests[2]['tools'] as List).single)['function'],
        )['name'],
        'finish',
      );
    });
    test('未配置模型价格时工具明确失败，不生成免费报告', () async {
      final cost = await install('plugins-group-cost-report');
      await agent.saveProvider(
        AgentProvider(
          id: 'model',
          name: '未标价测试',
          model: 'fixture',
          baseUrl: 'http://127.0.0.1:1/v1',
        ),
      );
      await connect([cost.id]);
      model.handler = (n, _) async => n == 1
          ? toolCall('group-cost-report__group_cost_report')
          : core.answer('请先配置价格');
      transport.receive(content: '金额统计');
      await core.eventually(() => transport.sent.isNotEmpty);
      expect(
        jsonEncode(model.requests.last['messages']),
        contains('未配置的费用不会按 0 元计算'),
      );
      expect(jsonEncode(transport.sent), isNot(contains('本群花费统计')));
    });
    test('真实申请事件按名单和开关同意且去重，失败不误报已同意', () async {
      final share = await install(
        'plugins-share-card',
        settings: {
          'autoApproveFriend': true,
          'autoApproveGroup': true,
          'ownerIds': '50005',
          'notifyOwner': true,
        },
      );
      await connect([share.id]);
      transport.request();
      await core.eventually(() => transport.sent.isNotEmpty);
      expect(
        transport.actions.where((a) => a['action'] == 'set_friend_add_request'),
        hasLength(1),
      );
      transport.request();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        transport.actions.where((a) => a['action'] == 'set_friend_add_request'),
        hasLength(1),
      );
      transport.failRequest = true;
      transport.request(flag: 'failed-flag', kind: 'group');
      await core.eventually(
        () => agent.logs.any((l) => text(l['message']).contains('未取得回执')),
      );
      expect(transport.sent, hasLength(1));
    });
    test('原分享插件复用Cookie默认开启时正常启动，布尔provider返回值保持可用', () async {
      final share = await install('plugins-share-card');
      expect(share.config['reuseMediaCookies'], true);
      await connect([share.id]);
      transport.receive(content: '查看 https://share.fixture.test/post');
      await core.eventually(() => transport.sent.isNotEmpty);
      await core.eventually(() => agent.busySessions.isEmpty);
      expect(
        agent.logs.where((line) => text(line['message']).contains('插件启动失败')),
        isEmpty,
        reason: jsonEncode(agent.logs),
      );
      expect(jsonEncode(model.requests.single['messages']), contains('分享网页标题'));
    });
    test('原VoxCPM提交任务503时说明服务不可用，不伪造语音回执', () async {
      await agent.shutdown();
      agent.dispose();
      final voiceHttp = UnavailableVoiceHttp();
      model = core.FakeAgentModel();
      agent = AgentController(
        store: AgentStore.memory(),
        http: voiceHttp,
        model: model,
        transportFactory: (c) => transport = ServiceTransport(c),
      );
      await agent.initialize();
      await agent.saveProvider(
        AgentProvider(
          id: 'model',
          name: '测试',
          baseUrl: 'http://127.0.0.1:1/v1',
          model: 'fixture',
        ),
      );
      await agent.savePreset(
        AgentPreset(
          id: 'assistant',
          name: '测试',
          prompt: '按实际结果回复',
          providerId: 'model',
        ),
      );
      final voice = await install(
        'skills-voxcpm-voice',
        settings: {'apiBase': 'https://voice.fixture.test'},
      );
      await connect([], skills: [voice.id]);
      model.handler = (n, _) async => n == 1
          ? toolCall('voxcpm-voice__read_aloud', {'text': '你好，这是语音测试'})
          : core.answer('语音服务暂不可用，请稍后重试');
      transport.receive();
      await core.eventually(() => transport.sent.isNotEmpty);
      await core.eventually(() => agent.busySessions.isEmpty);
      expect(jsonEncode(transport.sent), isNot(contains('record')));
      expect(jsonEncode(model.requests.last['messages']), contains('HTTP 503'));
      expect(
        jsonEncode(model.requests.last['messages']),
        contains('本轮没有取得语音发送回执'),
      );
      expect(
        agent.logs.any(
          (line) =>
              line['stage'] == 'tool-result' &&
              text(line['message']).contains('HTTP 503'),
        ),
        true,
      );
    });
    test('原Whale语音包通过WSS合成并等待真实发送完成', () async {
      final whale = await install('plugins-whale-voice');
      await connect([whale.id]);
      model.handler = (n, _) async => n == 1
          ? toolCall('whale-voice__speak', {'text': '语音测试'})
          : toolCall('finish');
      transport.receive();
      try {
        await core.eventually(() => transport.sent.isNotEmpty);
      } catch (_) {
        fail(
          jsonEncode({
            'logs': agent.logs,
            'requests': model.requests,
            'socketCount': http.sockets.length,
            'socketFrames': http.sockets.map((s) => s.sent.length).toList(),
          }),
        );
      }
      await core.eventually(() => agent.busySessions.isEmpty);
      expect(transport.sent.single['message'], isA<List>());
      expect(jsonEncode(transport.sent.single), contains('record'));
      expect(http.sockets, hasLength(1));
      expect(http.sockets.single.sent, hasLength(2));
      expect(http.sockets.single.closed, true);
      expect(
        agent.logs.any((l) => l['level'] == 'error'),
        false,
        reason: jsonEncode(agent.logs),
      );
    });
    test('语音网络失败不会伪造发送成功，模型收到可解释的错误', () async {
      http.failVoice = true;
      final whale = await install('plugins-whale-voice');
      await connect([whale.id]);
      model.handler = (n, _) async => n == 1
          ? toolCall('whale-voice__speak', {'text': '失败测试'})
          : core.answer('语音服务暂不可用');
      transport.receive();
      await core.eventually(() => transport.sent.isNotEmpty);
      expect(jsonEncode(transport.sent), isNot(contains('base64://')));
      expect(jsonEncode(model.requests.last['messages']), contains('没有取得发送回执'));
      expect(
        agent.logs.any(
          (l) =>
              l['level'] == 'warning' &&
              text(l['message']).contains('WebSocket'),
        ),
        true,
      );
    });
    test('分享自动注入和OCR通过当前OneBot，余额关键词钩子实际生效', () async {
      final share = await install('plugins-share-card');
      final balance = await install(
        'skills-api-beggar',
        settings: {
          'balanceUrl': 'https://balance.fixture.test/balance',
          'apiKey': 'fixture-owned-api-key',
        },
      );
      await connect([share.id], skills: [balance.id]);
      transport.receive(
        id: '1',
        content: '查余额，看看这个 https://share.fixture.test/post',
      );
      await core.eventually(() => transport.sent.isNotEmpty);
      expect(jsonEncode(model.requests.first['messages']), contains('分享网页标题'));
      expect(
        jsonEncode(model.requests.first['messages']),
        contains('api-beggar__check_balance'),
      );
      model.handler = (n, _) async => n == 2
          ? toolCall('share-card__read_image_text', {
              'image': 'https://images.fixture.test/screenshot.png',
            })
          : core.answer('已经识别');
      await core.eventually(() => agent.busySessions.isEmpty);
      transport.receive(id: '2', content: '识别文字');
      await core.eventually(() => transport.sent.length == 2);
      expect(
        transport.actions.any((a) => a['action'] == 'ocr_image'),
        true,
        reason: jsonEncode(agent.logs),
      );
      expect(jsonEncode(model.requests.last['messages']), contains('图片里的测试文字'));
      expect(
        jsonEncode(model.requests),
        isNot(contains('fixture-owned-api-key')),
      );
    });
    test('原QQ自身资料工具只操作当前账号，演练不写入，真实修改同步显示昵称', () async {
      final self = await install('skills-qq-self', settings: {'dryRun': true});
      await connect([], skills: [self.id]);
      model.handler = (n, _) async => n == 1
          ? toolCall('qq-self__update_profile', {'nickname': '新的测试昵称'})
          : core.answer('演练完成');
      transport.receive(id: '1', content: '修改昵称');
      await core.eventually(() => transport.sent.isNotEmpty);
      expect(
        transport.actions.where((a) => a['action'] == 'set_qq_profile'),
        isEmpty,
      );
      await agent.saveExtension(
        self.copyWith(
          enabled: true,
          settings: {
            ...self.config,
            'dryRun': false,
            'profileCooldownMinutes': 0,
          },
        ),
      );
      model.handler = (n, _) async => n == 3
          ? toolCall('qq-self__update_profile', {'nickname': '新的测试昵称'})
          : core.answer('修改完成');
      transport.receive(id: '2', content: '确认修改昵称');
      await core.eventually(() => transport.sent.length == 2);
      expect(
        transport.actions.where((a) => a['action'] == 'set_qq_profile'),
        hasLength(1),
        reason: jsonEncode(model.requests.last['messages']),
      );
      expect(agent.nickname('test'), '新的测试昵称');
    });
    test('热点原插件持久保存知识，其他插件可调用函数能力，按关键词注入', () async {
      final hot = await install(
        'plugins-hot-trend-tracker',
        settings: {'catchUpOnStart': false, 'notifyChatKey': ''},
      );
      await agent.importPackage(
        fixture.bundle(
          extra: {'id': 'hot-client'},
          source: r'''
        let api;export function setup(a){api=a;a.registerTool({id:'collect',parameters:{type:'object',properties:{}},async execute(){const provider=api.capability('knowledge.hot-trends');return {content:JSON.stringify(await provider({action:'collect'}))};}});}
      ''',
        ),
      );
      final client = agent.extensions.firstWhere((e) => e.id == 'hot-client');
      await agent.saveExtension(client.copyWith(enabled: true));
      await connect([hot.id], skills: [client.id]);
      model.handler = (n, _) async =>
          n == 1 ? toolCall('hot-client__collect') : core.answer('已收集热点');
      transport.receive(id: '1', content: '收集热点');
      await core.eventually(() => transport.sent.isNotEmpty);
      expect(
        http.requests.where(
          (r) => {'tieba.baidu.com', 'api.bilibili.com'}.contains(r.uri.host),
        ),
        hasLength(2),
        reason: jsonEncode(agent.logs),
      );
      expect(
        object(
          jsonDecode(
            text(
              object((model.requests[1]['messages'] as List).last)['content'],
            ),
          ),
        )['added'],
        2,
      );
      await core.eventually(() => agent.busySessions.isEmpty);
      transport.receive(id: '2', content: '最近有什么热梗');
      await core.eventually(() => transport.sent.length == 2);
      expect(jsonEncode(model.requests.last['messages']), contains('测试热梗小猫'));
      await core.eventually(() => agent.busySessions.isEmpty);
      final starts = agent.logs
          .where((line) => text(line['message']).contains('定时器已启动'))
          .length;
      transport.online = false;
      transport.onState?.call();
      transport.online = true;
      transport.onState?.call();
      await core.eventually(
        () =>
            agent.logs
                .where((line) => text(line['message']).contains('定时器已启动'))
                .length >
            starts,
      );
      final before = http.requests.length;
      await agent.disconnect('test');
      await agent.connect('test');
      transport.receive(id: '3', content: '最近有什么热梗');
      await core.eventually(() => transport.sent.isNotEmpty);
      expect(jsonEncode(model.requests.last['messages']), contains('测试热梗小猫'));
      expect(http.requests.length, before);
    });
    test('站点Cookie限定在原包配置的对应域名，不转发到分享目标', () async {
      await agent.importPackage(
        fixture.bundle(
          extra: {
            'id': 'cookies',
            'permissions': ['web_fetch'],
            'settings': {'bilibiliCookie': 'fixture-cookie-value'},
            'configSchema': {
              'bilibiliCookie': {'type': 'string', 'secret': true},
            },
          },
          source: r'''
        export function setup(api){api.registerTool({id:'check',parameters:{type:'object',properties:{url:{type:'string'}}},async execute(ctx,args){const r=await api.fetch(args.url,{headers:{Cookie:api.config().bilibiliCookie}});return {content:String(r.status)};}});}
      ''',
        ),
      );
      final e = agent.extensions.firstWhere((e) => e.id == 'cookies');
      await agent.saveExtension(e.copyWith(enabled: true));
      Future<Json> call(String url) => agent.packages.run(
        manifest: e.manifest,
        settings: e.config,
        operation: 'tool',
        args: {
          'id': 'check',
          'args': {'url': url},
        },
        scope: 'cookie-test',
        active: () => true,
      );
      expect((await call('https://api.bilibili.com/test'))['content'], '200');
      final before = http.requests.length;
      await expectLater(
        call('https://foreign.fixture.test/test'),
        throwsA(isA<AgentException>()),
      );
      expect(http.requests.length, before);
    });
  }, skip: skip);
}
