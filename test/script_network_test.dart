import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/plugins/script_plugin.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';

PluginMessage query(String text) => PluginMessage(
  messageId: 'm',
  sessionId: 'g',
  senderId: 'u',
  senderName: '用户',
  content: text,
  messageType: 0,
  isGroup: true,
  timestamp: DateTime.now(),
);

Future<ScriptPlugin> load(
  String id,
  Map<String, dynamic> config,
  Future<dynamic> Function(Map<String, dynamic>) network,
) async {
  final data =
      jsonDecode(File('plugins/$id/plugin.json').readAsStringSync())
          as Map<String, dynamic>;
  data['script']['source'] = File('plugins/$id/main.ht').readAsStringSync();
  final definition = PluginManifest.parse(jsonEncode(data));
  final info = definition.toInfo()..config.addAll(config);
  final plugin = ScriptPlugin(info, definition, networkForTesting: network);
  addTearDown(plugin.onDisable);
  await plugin.onEnable();
  return plugin;
}

void main() {
  test('真实天气脚本：自然命令、城市匹配、实况/预报/IP、空数据和业务错误', () async {
    final requests = <Map<String, dynamic>>[];
    var status = 200;
    String? errorCode;
    final plugin = await load(
      'weather_plugin',
      {'amap_key': 'fixture-amap-key', 'default_city': '北京'},
      (request) async {
        requests.add(request);
        final url = Uri.parse(request['url'] as String);
        expect(url.host, 'restapi.amap.com');
        expect(url.queryParameters['key'], 'fixture-amap-key');
        if (errorCode != null) {
          return {
            'status': status,
            'data': {
              'status': '0',
              'infocode': errorCode,
              'info': 'fixture-amap-key private raw error',
            },
          };
        }
        if (url.path.endsWith('district')) {
          return {
            'status': status,
            'data': {
              'status': '1',
              'count': '1',
              'districts': [
                {'name': '北京市', 'adcode': '110000', 'level': 'city'},
              ],
            },
          };
        }
        if (url.path.endsWith('/ip')) {
          return {
            'status': status,
            'data': {
              'status': '1',
              'province': '北京市',
              'city': '北京市',
              'adcode': '110000',
            },
          };
        }
        if (url.queryParameters['extensions'] == 'all') {
          return {
            'status': status,
            'data': {
              'status': '1',
              'forecasts': [
                {
                  'city': '北京市',
                  'casts': [
                    {
                      'date': '2026-10-20',
                      'dayweather': '晴',
                      'nightweather': '多云',
                      'nighttemp': '10',
                      'daytemp': '20',
                    },
                  ],
                },
              ],
            },
          };
        }
        return {
          'status': status,
          'data': {
            'status': '1',
            'lives': [
              {'city': '北京市', 'weather': '阴', 'temperature': 0, 'humidity': []},
            ],
          },
        };
      },
    );
    for (final text in ['天气 北京', '查询天气 北京', '/weather 110000', '天气：北京']) {
      final result = await plugin.execute(query(text));
      expect(result!.content, contains('温度：0℃'), reason: text);
      expect(result.content, contains('湿度：暂无数据'));
      expect(result.content, isNot(contains('暂无数据%')));
    }
    expect(
      (await plugin.execute(query('天气预报 北京')))!.content,
      contains('10～20℃'),
    );
    expect(
      (await plugin.execute(query('城市编码 北京')))!.content,
      contains('110000'),
    );
    expect(
      (await plugin.execute(query('查ip地址 114.114.114.114')))!.content,
      contains('归属地：北京市'),
    );
    expect(await plugin.execute(query('今天天气真好')), isNull);
    final before = requests.length;
    expect((await plugin.execute(query('/ip ::1')))!.content, contains('IPv4'));
    expect(
      (await plugin.execute(query('/ip 999.1.1.1')))!.content,
      contains('IPv4'),
    );
    expect(requests.length, before);
    for (final entry in {
      '10001': 'Key 无效',
      '10003': '额度已用完',
      '10004': '过于频繁',
      '10005': '白名单',
      '10007': '数字签名',
      '10009': 'Key 类型不匹配',
      '40000': '余额不足',
      '99999': '暂时不可用',
    }.entries) {
      errorCode = entry.key;
      final result = (await plugin.execute(query('/天气 110000')))!.content;
      expect(result, contains(entry.value));
      expect(result, contains(entry.key));
      expect(result, isNot(contains('fixture-amap-key')));
      expect(result, isNot(contains('raw error')));
    }
    errorCode = null;
    status = 503;
    expect(
      (await plugin.execute(query('/天气 110000')))!.content,
      contains('HTTP 503'),
    );
  });

  test('真实翻译脚本只提交注释数组，保留代码，异常结果不进行不安全替换', () async {
    var response = '[" translated comment"]';
    var reason = 'stop';
    final requests = <Map<String, dynamic>>[];
    final plugin = await load(
      'translate_comment',
      {
        'api_key': 'fixture-deepseek-key',
        'target_lang': '中文',
        'model': 'deepseek-chat',
      },
      (request) async {
        requests.add(request);
        expect(request['url'], 'https://api.deepseek.com/chat/completions');
        expect(
          request['headers']['Authorization'],
          'Bearer fixture-deepseek-key',
        );
        return {
          'status': 200,
          'data': {
            'choices': [
              {
                'finish_reason': reason,
                'message': {'content': response},
              },
            ],
          },
        };
      },
    );
    const source =
        '/translate ```python\n# original comment\nprint("keep me exactly")\n```';
    final translated = await plugin.execute(query(source));
    expect(translated!.content, contains('translated comment'));
    expect(translated.content, contains('print("keep me exactly")'));
    final body = requests.single['body'] as Map;
    final sent = body['messages'][1]['content'] as String;
    expect(jsonDecode(sent), isA<List>());
    expect(sent, isNot(contains('keep me exactly')));
    for (final invalid in [
      'not JSON',
      '[]',
      '["unsafe */ text"]',
      '["new\\nline"]',
      '[123]',
    ]) {
      response = invalid;
      final result = (await plugin.execute(query(source)))!.content;
      expect(result, contains('保留原代码'), reason: invalid);
      expect(result, isNot(contains('fixture-deepseek-key')));
    }
    reason = 'length';
    expect((await plugin.execute(query(source)))!.content, contains('未正常结束'));
    reason = 'stop';
    response = 'hello';
    expect((await plugin.execute(query('/翻译 你好')))!.content, 'hello');
    expect((requests.last['body'] as Map)['messages'][1]['content'], '你好');
  });

  test('未授权域名不能触达网络，脚本错误不泄露 secret 配置', () async {
    final data =
        jsonDecode(
              File(
                'plugins/examples/hello_script/plugin.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    data['config_schema'] = [
      {'key': 'api_key', 'label': 'Key', 'type': 'secret', 'default': ''},
    ];
    data['script']['source'] =
        "function main(ctx) { if (ctx.phase == 'enable') { return null } return {error:ctx.config['api_key']} }";
    final definition = PluginManifest.parse(jsonEncode(data));
    final plugin = ScriptPlugin(
      definition.toInfo()..config['api_key'] = 'must-not-leak',
      definition,
    );
    addTearDown(plugin.onDisable);
    await plugin.onEnable();
    await expectLater(
      plugin.execute(query('/hello')),
      throwsA(
        isA<PluginManifestException>().having(
          (e) => e.message,
          'safe error',
          isNot(contains('must-not-leak')),
        ),
      ),
    );
  });
}
