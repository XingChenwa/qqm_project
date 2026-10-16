import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/core/plugins/manifest_plugin.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';
import 'package:qqm_plugins/daily_club/plugin.dart';
import 'package:qqm_plugins/dice_plugin/plugin.dart';
import 'package:qqm_plugins/group_games/plugin.dart';
import 'package:qqm_plugins/translate_comment/comment_spans.dart';
import 'package:qqm_plugins/translate_comment/plugin.dart';
import 'package:qqm_plugins/weather_plugin/amap_service.dart';
import 'package:qqm_plugins/weather_plugin/plugin.dart';

import 'support/fakes.dart';

PluginMessage event(
  String text, {
  String user = 'u1',
  String session = 'g1',
  String role = 'member',
  bool full = false,
  bool group = true,
  String callback = '',
}) => PluginMessage(
  messageId: 'source',
  sessionId: session,
  senderId: user,
  senderName: '小明',
  content: text,
  messageType: 0,
  isGroup: group,
  timestamp: DateTime.utc(2026, 10, 16),
  senderRole: role,
  isFullGroupMessage: full,
  eventType: callback.isEmpty ? 'message' : 'interaction',
  callbackData: callback,
);
PluginInfo info(String id, {Map<String, dynamic>? config}) => PluginInfo(
  id: id,
  name: id,
  version: '2',
  description: '',
  directory: '',
  config: config,
);
PluginHost memoryHost() {
  Map<String, dynamic> data = {};
  final store = PluginStore(() async => data, (next) async {
    data = next;
  });
  return PluginHost(store: () => store, help: () => 'test help');
}

Map<String, dynamic> definition({
  List<String>? permissions,
  List<dynamic>? rules,
  Map<String, dynamic>? extra,
}) => {
  'schema_version': 2,
  'id': 'custom_v2',
  'name': '测试',
  'version': '1',
  'description': 'v2 测试',
  'runtime': 'rules',
  'permissions': permissions ?? ['message:read', 'message:send'],
  'rules':
      rules ??
      [
        {
          'match': {'type': 'command', 'value': '测试'},
          'message': {'format': 'text', 'content': '收到 {{args}}'},
        },
      ],
  ...?extra,
};

class JsonAdapter implements HttpClientAdapter {
  Object body;
  int status;
  final requests = <RequestOptions>[];
  JsonAdapter(this.body, {this.status = 200});
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());
  test('插件数据拒绝超限并回滚，失败不堵塞队列，快照不能反向修改存储', () async {
    final host = memoryHost();
    await host.store.update('counter', (data) {
      data['value'] = 1;
    });
    await expectLater(
      host.store.update('counter', (data) {
        data['huge'] = 'x' * 524288;
      }),
      throwsFormatException,
    );
    expect(await host.store.read('counter'), {'value': 1});
    final snapshot = await host.store.snapshot();
    (snapshot['counter'] as Map)['value'] = 999;
    expect((await host.store.read('counter'))['value'], 1);
    expect(
      CommentDocument.parse(
        '#!/usr/bin/python\n# coding: utf-8\n# hello\n',
        'python',
      ).comments,
      ['hello'],
    );
  });
  test('v2 样例清单全部校验，旧版仍兼容，# 命令不吞 Markdown 标题', () {
    for (final path in [
      'hello_json/plugin.json',
      'hello_yaml/plugin.yaml',
      'http_echo/plugin.json',
      'buttons/plugin.json',
      'media/plugin.json',
    ]) {
      expect(
        PluginManifest.parse(
          File('plugins/examples/$path').readAsStringSync(),
        ).id,
        isNotEmpty,
      );
    }
    expect(parseSlashCommand('#签到')?.command, '签到');
    expect(parseSlashCommand('# 标题'), isNull);
  });

  test('富回复、媒体域名和按钮权限验证；管理员权限 fail closed', () async {
    final data = definition(
      rules: [
        {
          'match': {'type': 'command', 'value': '测试'},
          'permission': 'admin',
          'message': {'format': 'text', 'content': '管理功能'},
        },
      ],
    );
    final manifest = PluginManifest.parse(jsonEncode(data));
    final plugin = ManifestPlugin(manifest.toInfo(), manifest);
    expect((await plugin.execute(event('/测试')))?.content, contains('仅限'));
    expect(
      (await plugin.handleMessage(event('/测试', role: ''))),
      contains('仅限'),
    );
    expect(
      (await plugin.execute(event('/测试', role: 'admin')))?.content,
      '管理功能',
    );
    final media = definition(
      rules: [
        {
          'match': {'type': 'command', 'value': '测试'},
          'message': {
            'format': 'media',
            'media_url': 'https://cdn.example.com/a.png',
          },
        },
      ],
    );
    expect(
      () => PluginManifest.parse(jsonEncode(media)),
      throwsA(isA<PluginManifestException>()),
    );
    media['permissions'] = ['message:read', 'message:send', 'message:media'];
    media['media_hosts'] = ['cdn.example.com'];
    expect(
      PluginManifest.parse(jsonEncode(media)).rules.single.message!.mediaType,
      1,
    );
    media['media_hosts'] = ['other.example.com'];
    expect(
      () => PluginManifest.parse(jsonEncode(media)),
      throwsA(isA<PluginManifestException>()),
    );
    expect(
      () => PluginReply.fromMap({
        'format': 'text',
        'content': 'test',
        'buttons': [
          [
            {'label': '按钮', 'data': '/help'},
          ],
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => PluginManifest.parse(
        jsonEncode(definition(extra: {'listen_all': true})),
      ),
      throwsA(isA<PluginManifestException>()),
    );
  });

  test('命令免 @、普通关键词须授权全量监听；优先级和冷却生效', () async {
    final manager = PluginManager(MemoryStorage());
    addTearDown(manager.dispose);
    await manager.init();
    final raw = definition(
      rules: [
        {
          'match': {'type': 'command', 'value': '测试'},
          'reply': 'first',
        },
        {
          'match': {'type': 'exact', 'value': '普通词'},
          'reply': 'exact',
        },
      ],
      extra: {'priority': 1, 'cooldown_ms': 50},
    );
    await manager.installPlugin(jsonEncode(raw));
    await manager.enablePlugin('custom_v2');
    expect(
      (await manager.processMessage(event('#测试', full: true))).single.content,
      'first',
    );
    expect(await manager.processMessage(event('#测试', full: true)), isEmpty);
    expect(
      await manager.processMessage(event('普通词', full: true, user: 'u2')),
      isEmpty,
    );
    expect(
      (await manager.processMessage(event('普通词', user: 'u2'))).single.content,
      'exact',
    );
    raw['listen_all'] = true;
    raw['permissions'] = ['message:read', 'message:send', 'events:group-all'];
    await manager.installPlugin(jsonEncode(raw), replaceExisting: true);
    await manager.enablePlugin('custom_v2');
    expect(
      (await manager.processMessage(
        event('普通词', full: true, user: 'u3'),
      )).single.content,
      'exact',
    );
    expect(
      (await manager.processMessage(event('/帮助'))).single.content,
      contains('群互动游戏'),
    );
  });

  test('签到并发幂等、北京时间换日、会话和 AppID 隔离、旧数据重启保留', () async {
    var now = DateTime.utc(2026, 10, 16, 15, 59);
    final plugin = DailyClubPlugin(info('daily_club'), clock: () => now)
      ..host = memoryHost();
    final answers = await Future.wait(
      List.generate(12, (_) => plugin.execute(event('/签到'))),
    );
    expect(answers.where((a) => a!.content.contains('签到成功')), hasLength(1));
    expect((await plugin.execute(event('/积分')))?.content, contains('10 分'));
    now = now.add(const Duration(minutes: 2));
    expect((await plugin.execute(event('/签到')))?.content, contains('连续 2 天'));
    expect(
      (await plugin.execute(event('/积分', session: 'g2')))?.content,
      contains('0 分'),
    );
    expect((await plugin.execute(event('/排行')))?.content, contains('20 分'));
    final fortune = (await plugin.execute(event('/今日运势')))!.content;
    expect((await plugin.execute(event('/今日运势')))?.content, fortune);
    expect(
      (await plugin.execute(event('/签到', user: '')))?.content,
      contains('操作员'),
    );
    final storage = MemoryStorage(config: validConfig());
    final manager = PluginManager(storage);
    await manager.init();
    await manager.processMessage(event('/签到'));
    storage.config.appId = 'different-bot';
    expect(
      (await manager.processMessage(event('/积分'))).single.content,
      contains('0 分'),
    );
    // Restore the original exact AppID rather than assuming an identifier.
    final original = validConfig().appId;
    storage.config.appId = original;
    manager.dispose();
    final restored = PluginManager(storage);
    addTearDown(restored.dispose);
    await restored.init();
    expect(
      (await restored.processMessage(event('/积分'))).single.content,
      contains('10 分'),
    );
    expect(await restored.exportPluginData('daily_club'), contains('u1'));
    expect(restored.exportPlugin('daily_club'), isNot(contains('u1')));
    await expectLater(
      restored.clearPluginData('daily_club'),
      throwsA(isA<PluginManifestException>()),
    );
    await restored.disablePlugin('daily_club');
    await restored.clearPluginData('daily_club');
    expect(
      await restored.exportPluginData('daily_club'),
      isNot(contains('u1')),
    );
  });

  test('群投票记录唯一票、改票、权限、过期与旧按钮；猜数字隔离和限时', () async {
    var now = DateTime.utc(2026, 10, 16);
    final plugin = GroupGamesPlugin(
      info('group_games', config: {'enable_buttons': true}),
      random: Random(1),
      clock: () => now,
    )..host = memoryHost();
    final created = (await plugin.execute(event('/投票 创建 晚饭 | 火锅 | 烧烤')))!;
    expect(created.format, 'markdown');
    final callback = created.buttons.first.first.data;
    final voted = await plugin.execute(event('', callback: callback));
    expect(voted?.content, contains('共 1 人参与'));
    expect(
      (await plugin.execute(event('', callback: callback)))?.content,
      contains('共 1 人参与'),
    );
    expect(
      (await plugin.execute(event('/投票 选择 2')))?.content,
      contains('烧烤：1 票'),
    );
    expect(
      (await plugin.execute(event('/投票 结束', user: 'u2')))?.content,
      contains('仅发起人'),
    );
    expect(
      (await plugin.execute(
        event('/投票 结束', user: 'admin', role: 'admin'),
      ))?.content,
      contains('已结束'),
    );
    await plugin.execute(event('/投票 创建 再投 | A | B'));
    expect(
      (await plugin.execute(event('', callback: callback)))?.content,
      contains('旧投票'),
    );
    expect(
      (await plugin.execute(event('/投票 结果', session: 'g2')))?.content,
      contains('没有有效'),
    );
    expect(
      (await plugin.execute(event('/猜数字 开始')))?.content,
      contains('1–100'),
    );
    expect(
      (await plugin.execute(event('/猜数字 结束', user: 'other')))?.content,
      contains('仅发起人'),
    );
    now = now.add(const Duration(minutes: 16));
    expect((await plugin.execute(event('/猜数字 50')))?.content, contains('过期'));
    now = now.add(const Duration(days: 1));
    expect((await plugin.execute(event('/投票 结果')))?.content, contains('没有有效'));
    expect(
      (await plugin.execute(event('/投票 结果', group: false)))?.content,
      contains('群聊'),
    );
  });

  test('随机游乐场边界、修正、硬币、选项、排序、范围和猜拳', () async {
    final plugin = DicePlugin(info('dice_plugin'), random: Random(2));
    expect(await plugin.onCommand('dice', ['2d6+3']), contains('2d6+3'));
    expect(await plugin.onCommand('dice', ['0d6']), contains('至少'));
    expect(await plugin.onCommand('dice', ['101d6']), contains('过大'));
    expect(await plugin.onCommand('硬币', ['21']), contains('用法'));
    expect(await plugin.onCommand('硬币', ['3']), contains('抛硬币'));
    expect(
      await plugin.onCommand('选择', ['A', '|', 'B']),
      anyOf('我选：A', '我选：B'),
    );
    expect(
      await plugin.onCommand('打乱', ['A', '|', 'B']),
      allOf(contains('A'), contains('B')),
    );
    expect(await plugin.onCommand('随机数', ['5', '5']), '随机数：5');
    expect(await plugin.onCommand('随机数', ['100', '1']), contains('用法'));
    expect(await plugin.onCommand('猜拳', ['石头']), contains('你出石头'));
  });

  test('高德预报使用 all，城市编码不伪造接口，帮助不请求网络', () async {
    final adapter = JsonAdapter({
      'status': '1',
      'infocode': '10000',
      'forecasts': [
        {
          'city': '北京',
          'reporttime': '2026-10-16 08:00',
          'casts': [
            {
              'date': '2026-10-16',
              'dayweather': '晴',
              'nightweather': '多云',
              'daytemp': '22',
              'nighttemp': '12',
            },
          ],
        },
      ],
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final plugin = WeatherPlugin(
      info('weather_plugin', config: {'amap_key': 'test-key'}),
      amapService: AmapService(dio: dio),
    );
    expect(
      await plugin.onMessage(event('天气预报 110000')),
      allOf(contains('12～22℃'), contains('高德')),
    );
    expect(adapter.requests.single.queryParameters['extensions'], 'all');
    expect(await plugin.onMessage(event('城市编码 110000')), contains('110000'));
    expect(await plugin.onMessage(event('天气 帮助')), contains('用法'));
    expect(adapter.requests, hasLength(1));
  });

  test('注释按片段替换保留字符串/代码/换行；复杂结构拒绝，普通代码块不触发', () async {
    const source = '# hello\ntext = "# not comment"\nprint(text) # world\n';
    final document = CommentDocument.parse(source, 'python');
    expect(document.comments, ['hello', 'world']);
    expect(
      document.replace(['你好', '世界']),
      '# 你好\ntext = "# not comment"\nprint(text) # 世界\n',
    );
    expect(() => document.replace(['bad\ncode', 'ok']), throwsFormatException);
    expect(
      () => CommentDocument.parse('const r = /x/;', 'js'),
      throwsA(isA<CommentParseException>()),
    );
    final adapter = JsonAdapter({
      'choices': [
        {
          'finish_reason': 'stop',
          'message': {'content': '["你好", "世界"]'},
        },
      ],
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final plugin = TranslateCommentPlugin(
      info(
        'translate_comment',
        config: {'api_key': 'private-test-key', 'target_lang': '中文'},
      ),
      dio: dio,
    );
    expect(await plugin.onMessage(event('```python\n# hi\n```')), isNull);
    final result = await plugin.onCommand('translate', [
      '```python\n$source```',
    ]);
    expect(result, contains('print(text) # 世界'));
    final request = adapter.requests.single;
    expect(request.uri.host, 'api.deepseek.com');
    expect(request.followRedirects, false);
    expect(jsonEncode(request.data), isNot(contains('print(text)')));
    adapter.status = 401;
    adapter.body = {
      'error': {'message': 'private-test-key leak'},
    };
    final error = await plugin.onCommand('翻译', ['test']);
    expect(error, contains('密钥无效'));
    expect(error, isNot(contains('private-test-key')));
    adapter.status = 200;
    adapter.body = {
      'choices': [
        {
          'finish_reason': 'length',
          'message': {'content': 'truncated'},
        },
      ],
    };
    expect(await plugin.onCommand('翻译', ['test']), contains('截断'));
  });

  test('官方 group_member_openid 路由回调，重复只执行业务一次，不误用频道 user_id', () async {
    final gateway = TestGateway();
    final api = RecordingApi();
    final bot = BotClient(
      MemoryStorage(config: validConfig()),
      apiService: api,
      webSocketService: gateway,
    );
    addTearDown(bot.dispose);
    final delivered = <MessageModel>[];
    bot.onMessageReceived = delivered.add;
    Map<String, dynamic> callback(String id, {bool actor = true}) => {
      'id': id,
      'eventType': 'INTERACTION_CREATE',
      'data': {
        'id': id,
        '_eventId': 'outer-$id',
        'type': 11,
        'scene': 'group',
        'chat_type': 1,
        'application_id': validConfig().appId,
        'group_openid': 'g1',
        if (actor) 'group_member_openid': 'u1',
        'data': {
          'type': 11,
          'resolved': {
            'button_data': 'qqm:group_games:vote:nonce:1',
            'user_id': 'guild-only-id',
          },
        },
      },
    };
    gateway.onDispatch!(
      'INTERACTION_CREATE',
      Map<String, dynamic>.from(callback('button1')['data']),
    );
    gateway.onDispatch!(
      'INTERACTION_CREATE',
      Map<String, dynamic>.from(callback('button1')['data']),
    );
    gateway.onDispatch!(
      'INTERACTION_CREATE',
      Map<String, dynamic>.from(callback('button2', actor: false)['data']),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(delivered, hasLength(1));
    expect(delivered.single.senderId, 'u1');
    expect(delivered.single.sessionId, 'g1');
    expect(delivered.single.extra?['pluginEventId'], 'outer-button1');
    expect(api.interactionAcks, ['button1', 'button2']);
  });
}
