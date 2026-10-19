import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/core/plugins/weather_plugin.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/services/amap_service.dart';
import 'package:qq_bot_manager/ui/widgets/plugin_panel.dart';

import 'support/fakes.dart';

class AmapAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Object district = {
    'status': '1',
    'infocode': '10000',
    'count': '1',
    'districts': [
      {'name': '北京市', 'adcode': '110000', 'level': 'province'},
    ],
  };
  Object weather = {
    'status': '1',
    'infocode': '10000',
    'lives': [
      {
        'province': '北京',
        'city': '北京市',
        'adcode': '110000',
        'weather': '晴',
        'temperature': '23',
        'humidity': '42',
        'winddirection': '东北',
        'windpower': '≤3',
        'reporttime': '2026-10-15 09:30:00',
      },
    ],
  };
  Object ip = {
    'status': '1',
    'infocode': '10000',
    'province': '江苏省',
    'city': '南京市',
    'adcode': '320100',
    'rectangle': '118,31;119,32',
  };
  int statusCode = 200;
  DioExceptionType? errorType;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (errorType != null) {
      throw DioException(
        requestOptions: options,
        type: errorType!,
        message: 'secret-key-in-error',
      );
    }
    final body = switch (options.uri.path) {
      '/v3/config/district' => district,
      '/v3/weather/weatherInfo' => weather,
      '/v3/ip' => ip,
      _ => throw StateError('意外的 API 路径'),
    };
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

PluginMessage query(String text) => PluginMessage(
  messageId: 'id',
  sessionId: 'group',
  senderId: 'sender',
  senderName: '用户',
  content: text,
  messageType: 0,
  isGroup: true,
  timestamp: DateTime.now(),
);

void main() {
  late AmapAdapter adapter;
  late WeatherPlugin plugin;
  late Dio dio;

  setUp(() {
    adapter = AmapAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    plugin = WeatherPlugin(
      PluginInfo(
        id: 'weather_plugin',
        name: '天气与 IP 查询',
        version: '1.1.0',
        description: '',
        directory: '',
        config: {'amap_key': 'test-amap-key'},
      ),
      amapService: AmapService(dio: dio),
    );
  });
  tearDown(() => dio.close(force: true));

  test('中文和英文天气指令查询高德实况，城市名先解析为 adcode，重复查询只缓存编码', () async {
    for (final command in [
      '天气 北京',
      '查询天气 北京',
      '查天气 北京',
      '天气查询 北京',
      'weather 北京',
      'tianqi 北京',
      '天气：北京',
    ]) {
      final text = await plugin.onMessage(query(command));
      expect(text, contains('实况天气'));
      expect(text, contains('温度：23℃'));
      expect(text, contains('湿度：42%'));
      expect(text, contains('风况：东北风 ≤3级'));
      expect(text, contains('2026-10-15 09:30:00'));
      expect(text, contains('数据来源：高德地图'));
      expect(text, isNot(contains('模拟')));
    }
    expect(
      adapter.requests.where((r) => r.uri.path == '/v3/config/district'),
      hasLength(1),
    );
    final first = adapter.requests.first;
    expect(first.uri.scheme, 'https');
    expect(first.uri.host, 'restapi.amap.com');
    expect(first.uri.queryParameters['keywords'], '北京');
    expect(first.uri.queryParameters['subdistrict'], '0');
    expect(first.uri.queryParameters['key'], 'test-amap-key');
    final weather = adapter.requests.last;
    expect(weather.uri.queryParameters['city'], '110000');
    expect(weather.uri.queryParameters['extensions'], 'base');
    expect(weather.uri.queryParameters['output'], 'JSON');
    expect(weather.followRedirects, isFalse);
    expect(
      adapter.requests.where((r) => r.uri.path == '/v3/weather/weatherInfo'),
      hasLength(7),
    );
  });

  test('中文斜杠命令和英文别名直接查询六位编码，不发送行政区查询', () async {
    for (final alias in [
      '天气',
      '查询天气',
      '天气查询',
      '查天气',
      'weather',
      'tianqi',
      'WEATHER',
    ]) {
      expect(await plugin.onCommand(alias, ['110105']), contains('实况天气'));
    }
    expect(adapter.requests, hasLength(7));
    expect(
      adapter.requests.map((r) => r.uri.path),
      everyElement('/v3/weather/weatherInfo'),
    );
    expect(adapter.requests.last.uri.queryParameters['city'], '110105');
  });

  test('不带城市时给用法，配置默认城市后可直接查询天气，更新 Key 后不复用旧 Key 的编码缓存', () async {
    expect(await plugin.onMessage(query('查询天气')), contains('用法'));
    expect(adapter.requests, isEmpty);
    await plugin.updateConfig({'default_city': '北京'});
    expect(await plugin.onMessage(query('查询天气')), contains('实况天气'));
    await plugin.updateConfig({'amap_key': 'new-key'});
    expect(await plugin.onCommand('天气', []), contains('实况天气'));
    expect(
      adapter.requests.where((r) => r.uri.path == '/v3/config/district'),
      hasLength(2),
    );
    expect(adapter.requests.last.uri.queryParameters['key'], 'new-key');
  });

  test('无 Key 时返回配置说明，不发请求；普通聊天和不认识的命令不触发插件', () async {
    await plugin.updateConfig({'amap_key': ''});
    expect(await plugin.onMessage(query('天气 北京')), contains('尚未配置'));
    expect(await plugin.onCommand('ip', ['114.114.114.114']), contains('尚未配置'));
    for (final text in [
      '今天的天气不错',
      '请看一下天气 北京',
      '这个IP地址是什么',
      'weathering 北京',
      '天气 北京\n其他正文',
    ]) {
      expect(await plugin.onMessage(query(text)), isNull);
    }
    expect(await plugin.onCommand('unknown', []), isNull);
    expect(adapter.requests, isEmpty);
  });

  test('IP 查询归同一插件，中文别名和大小写可用，始终查询指定的 IPv4', () async {
    for (final text in [
      '查ip地址 114.114.114.114',
      '查询IP地址 114.114.114.114',
      'IP 114.114.114.114',
      'ip查询：114.114.114.114',
    ]) {
      final result = await plugin.onMessage(query(text));
      expect(result, contains('IP：114.114.114.114'));
      expect(result, contains('归属地：江苏省 南京市'));
      expect(result, contains('行政区编码：320100'));
      expect(result, contains('不代表用户的实时位置'));
    }
    expect(await plugin.onCommand('ip', ['114.114.114.114']), contains('南京市'));
    expect(adapter.requests, hasLength(5));
    for (final request in adapter.requests) {
      expect(request.uri.path, '/v3/ip');
      expect(request.uri.queryParameters['ip'], '114.114.114.114');
    }
  });

  test('省略 IP 不定位运行程序的机器，错误地址和 IPv6 在请求前拦截', () async {
    expect(
      await plugin.onMessage(query('查ip地址')),
      contains('QQ 官方消息不提供发送者 IP'),
    );
    expect(await plugin.onCommand('ip', []), contains('用法'));
    for (final ip in [
      '999.1.1.1',
      '1.2.3',
      '1.2.3.04',
      '-1.1.1.1',
      '2001:db8::1',
      'https://example.com',
      '114.114.114.114 other',
    ]) {
      expect(await plugin.onCommand('ip', [ip]), contains('有效的 IPv4'));
    }
    expect(adapter.requests, isEmpty);
  });

  test('IP 空数组字段、国外无结果、局域网和直辖市不会显示 [] 或重复城市', () async {
    adapter.ip = {
      'status': '1',
      'province': [],
      'city': [],
      'adcode': [],
      'rectangle': [],
    };
    final empty = await plugin.onCommand('ip', ['8.8.8.8']);
    expect(empty, contains('未查询到位置'));
    expect(empty, contains('不支持国外 IP'));
    expect(empty, isNot(contains('[]')));
    adapter.ip = {'status': '1', 'province': '局域网', 'city': [], 'adcode': []};
    expect(await plugin.onCommand('ip', ['192.168.1.1']), contains('归属地：局域网'));
    adapter.ip = {
      'status': '1',
      'province': '北京市',
      'city': '北京市',
      'adcode': '110000',
    };
    final city = await plugin.onCommand('ip', ['114.114.114.114']);
    expect(city, contains('归属地：北京市\n'));
    expect(city, isNot(contains('北京市 北京市')));
  });

  test('未知、同名地区和整个省份返回清晰提示，不猜测天气所属城市', () async {
    adapter.district = {'status': '1', 'count': '0', 'districts': []};
    expect(await plugin.onCommand('天气', ['不存在的城市']), contains('未找到'));
    adapter.district = {
      'status': '1',
      'count': '2',
      'districts': [
        {'name': '朝阳区', 'adcode': '110105', 'level': 'district'},
        {'name': '朝阳区', 'adcode': '220104', 'level': 'district'},
      ],
    };
    final ambiguous = await plugin.onCommand('天气', ['朝阳区']);
    expect(ambiguous, contains('找到多个地区'));
    expect(ambiguous, contains('110105'));
    expect(ambiguous, contains('220104'));
    adapter.district = {
      'status': '1',
      'count': '1',
      'districts': [
        {'name': '广东省', 'adcode': '440000', 'level': 'province'},
      ],
    };
    expect(await plugin.onCommand('天气', ['广东']), contains('具体城市/区县'));
    expect(
      adapter.requests.map((r) => r.uri.path),
      everyElement('/v3/config/district'),
    );
  });

  test('高德 HTTP 200 业务错误按错误码显示中文原因，不泄露 Key 或原始服务错误', () async {
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
      adapter.weather = {
        'status': '0',
        'infocode': entry.key,
        'info': 'test-amap-key secret-server-error',
      };
      final result = await plugin.onCommand('天气', ['110105']);
      expect(result, contains(entry.value));
      expect(result, contains(entry.key));
      expect(result, isNot(contains('test-amap-key')));
      expect(result, isNot(contains('secret-server-error')));
    }
  });

  test('HTTP 错误、超时和断网均有中文反馈，异常不包含请求 URL 或 Key', () async {
    adapter.statusCode = 503;
    expect(await plugin.onCommand('天气', ['110105']), contains('HTTP 503'));
    adapter.statusCode = 200;
    adapter.errorType = DioExceptionType.receiveTimeout;
    expect(await plugin.onCommand('ip', ['114.114.114.114']), contains('超时'));
    adapter.errorType = DioExceptionType.connectionError;
    final result = await plugin.onCommand('天气', ['110105']);
    expect(result, contains('检查网络'));
    expect(result, isNot(contains('secret-key-in-error')));
    expect(result, isNot(contains('restapi.amap.com')));
  });

  test('空天气和异常响应不伪造天气，缺失字段与零度正常显示', () async {
    adapter.weather = {'status': '1', 'lives': []};
    expect(await plugin.onCommand('天气', ['110105']), contains('暂无实况天气'));
    adapter.weather = '<html>error</html>';
    expect(await plugin.onCommand('天气', ['110105']), contains('返回格式异常'));
    adapter.weather = {
      'status': '1',
      'lives': [
        {'city': '北京市', 'weather': '阴', 'temperature': 0, 'humidity': []},
      ],
    };
    final result = await plugin.onCommand('天气', ['110105']);
    expect(result, contains('温度：0℃'));
    expect(result, contains('湿度：暂无数据'));
    expect(result, contains('更新时间：暂无数据'));
    expect(result, isNot(contains('[]')));
  });

  test('插件管理器将中文、斜杠和 IP 指令都路由到原天气插件，关闭后不处理', () async {
    final manager = PluginManager(MemoryStorage());
    addTearDown(manager.dispose);
    await manager.init();
    await manager.enablePlugin('weather_plugin');
    for (final command in [
      '天气 北京',
      '查询天气 北京',
      '/天气 北京',
      '/查询天气 北京',
      '/weather 北京',
      '查ip地址 114.114.114.114',
      '/IP 114.114.114.114',
    ]) {
      final responses = await manager.processMessage(query(command));
      expect(responses.single.pluginId, 'weather_plugin');
      expect(responses.single.content, contains('尚未配置'));
    }
    await manager.disablePlugin('weather_plugin');
    expect(await manager.processMessage(query('/ip 114.114.114.114')), isEmpty);
  });

  testWidgets('天气插件可配置隐藏的高德 Key 和默认城市，保存到原插件且重新加载后恢复', (tester) async {
    final storage = MemoryStorage();
    final manager = PluginManager(storage);
    addTearDown(manager.dispose);
    await tester.runAsync(() => manager.init());
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: manager,
        child: const MaterialApp(home: Scaffold(body: PluginPanel())),
      ),
    );
    await tester.ensureVisible(find.byTooltip('配置高德天气与 IP 查询'));
    await tester.tap(find.byTooltip('配置高德天气与 IP 查询'));
    await tester.pumpAndSettle();
    expect(find.text('天气与 IP 查询配置'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(TextField),
                )
                .first,
          )
          .obscureText,
      isTrue,
    );
    await tester.enterText(find.byType(TextFormField).first, 'test-saved-key');
    await tester.enterText(find.byType(TextFormField).last, '深圳');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
      storage.storedPlugins['weather_plugin']?.config['amap_key'],
      'test-saved-key',
    );
    expect(
      storage.storedPlugins['weather_plugin']?.config['default_city'],
      '深圳',
    );
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => manager.init());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('配置高德天气与 IP 查询'));
    await tester.tap(find.byTooltip('配置高德天气与 IP 查询'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller
          ?.text,
      'test-saved-key',
    );
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).last)
          .controller
          ?.text,
      '深圳',
    );
    await tester.enterText(find.byType(TextFormField).last, '上海');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      storage.storedPlugins['weather_plugin']?.config['default_city'],
      '深圳',
    );
    expect(tester.takeException(), isNull);
  });
}
