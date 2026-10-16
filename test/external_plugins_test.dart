import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';
import 'package:qqm_plugins/weather_plugin/plugin.dart';

import 'support/fakes.dart';

PluginMessage pluginEvent(String content, {bool group = true}) => PluginMessage(
  messageId: 'source-1',
  sessionId: 'group-1',
  senderId: 'member-1',
  senderName: '小明',
  content: content,
  messageType: 0,
  isGroup: group,
  timestamp: DateTime.utc(2026, 10, 15),
);

Map<String, dynamic> jsonExample() =>
    jsonDecode(
          File('plugins/examples/hello_json/plugin.json').readAsStringSync(),
        )
        as Map<String, dynamic>;
Map<String, dynamic> httpExample(Uri endpoint) {
  final data =
      jsonDecode(
            File('plugins/examples/http_echo/plugin.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  (data['http'] as Map)['url'] = endpoint.toString();
  return data;
}

Future<PluginManager> pluginManager([MemoryStorage? storage]) async {
  final manager = PluginManager(storage ?? MemoryStorage());
  addTearDown(manager.dispose);
  await manager.init();
  return manager;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 此文件只访问自建回环服务器，不使用 Flutter 的 HTTP 400 占位器。
    HttpOverrides.global = null;
  });
  test('六个内置实现来自独立 plugins 包，旧 ID、启用状态和密钥配置保留', () async {
    final storage = MemoryStorage();
    storage.storedPlugins['weather_plugin'] = PluginInfo(
      id: 'weather_plugin',
      name: '旧天气',
      version: '1.0',
      description: '',
      directory: '',
      isEnabled: false,
      config: {'amap_key': 'old-private-key', 'default_city': '深圳'},
    );
    final manager = await pluginManager(storage);
    expect(manager.plugins.map((p) => p.info.id), [
      'example_plugin',
      'weather_plugin',
      'dice_plugin',
      'translate_comment',
      'daily_club',
      'group_games',
    ]);
    final weather = manager.plugins.singleWhere(
      (p) => p.info.id == 'weather_plugin',
    );
    expect(weather, isA<WeatherPlugin>());
    expect(weather.info.config['amap_key'], 'old-private-key');
    expect(weather.info.config['default_city'], '深圳');
    expect(weather.info.isEnabled, false);
    expect(weather.info.directory, 'plugins/weather_plugin');
    expect(
      weather.info.manifest['entrypoint'],
      'lib/weather_plugin/plugin.dart',
    );
    expect(await manager.uninstallPlugin('weather_plugin'), false);
    expect(File('plugins/lib/weather_plugin/plugin.dart').existsSync(), true);
  });

  test('JSON 插件默认停用；命令、完整匹配、配置和 Markdown 正文实际运行', () async {
    final manager = await pluginManager();
    final info = await manager.installPlugin(jsonEncode(jsonExample()));
    expect(info.isEnabled, false);
    expect(await manager.processMessage(pluginEvent('/hello 参数')), isEmpty);
    expect(await manager.enablePlugin(info.id), true);
    final result = await manager.processMessage(pluginEvent('/hello 参数'));
    expect(result.single.content, '你好，小明！\n你输入的参数：参数');
    await manager.updatePluginConfig(info.id, {'salutation': '欢迎'});
    expect(
      (await manager.processMessage(pluginEvent('/hello 第二次'))).single.content,
      startsWith('欢迎，小明'),
    );
    expect(await manager.processMessage(pluginEvent('请看开发者示例')), isEmpty);
    expect(
      (await manager.processMessage(pluginEvent('开发者示例'))).single.content,
      contains('**Markdown**'),
    );
    const code = '```dart\n  print("你好");\n```';
    expect(
      (await manager.processMessage(
        pluginEvent('/hello $code'),
      )).single.content,
      contains(code),
    );
  });

  test('YAML 使用相同协议，private 规则不会在群聊触发', () async {
    final manager = await pluginManager();
    final info = await manager.installPlugin(
      File('plugins/examples/hello_yaml/plugin.yaml').readAsStringSync(),
    );
    await manager.enablePlugin(info.id);
    expect(
      (await manager.processMessage(pluginEvent('/yamlhello'))).single.content,
      contains('YAML 插件'),
    );
    expect(await manager.processMessage(pluginEvent('YAML示例')), isEmpty);
    expect(
      (await manager.processMessage(
        pluginEvent('YAML示例', group: false),
      )).single.content,
      contains('单聊'),
    );
  });

  test('第三方清单与配置可恢复，卸载后重启不会复活；替换需确认且重新停用', () async {
    final storage = MemoryStorage();
    final manager = await pluginManager(storage);
    final source = jsonEncode(jsonExample());
    final info = await manager.installPlugin(source);
    await manager.updatePluginConfig(info.id, {'salutation': '保留配置'});
    await manager.enablePlugin(info.id);
    await expectLater(
      manager.installPlugin(source),
      throwsA(isA<PluginManifestException>()),
    );
    final updated = jsonExample()..['version'] = '1.1.0';
    await manager.installPlugin(jsonEncode(updated), replaceExisting: true);
    expect(manager.plugins.last.info.config['salutation'], '保留配置');
    expect(manager.plugins.last.info.isEnabled, false);
    await manager.enablePlugin(info.id);
    final restored = await pluginManager(storage);
    expect(
      (await restored.processMessage(pluginEvent('/hello'))).single.content,
      startsWith('保留配置'),
    );
    expect(await restored.uninstallPlugin(info.id), true);
    final afterUninstall = await pluginManager(storage);
    expect(afterUninstall.plugins, hasLength(6));
  });

  test('不能导入 Dart 执行代码、覆盖内置 ID 或声明未知权限', () async {
    final manager = await pluginManager();
    final builtinId = jsonExample()..['id'] = 'weather_plugin';
    await expectLater(
      manager.installPlugin(jsonEncode(builtinId)),
      throwsA(isA<PluginManifestException>()),
    );
    for (final data in [
      jsonExample()..['runtime'] = 'dart',
      jsonExample()..['schema_version'] = 99,
      jsonExample()
        ..['permissions'] = [
          'message:read',
          'message:send',
          'filesystem:write',
        ],
      jsonExample()..['rules'] = [],
      jsonExample()..['config'] = {'salutation': 1},
    ]) {
      expect(
        () => PluginManifest.parse(jsonEncode(data)),
        throwsA(isA<PluginManifestException>()),
      );
    }
    expect(
      () => PluginManifest.parse('x' * (PluginManifest.maxBytes + 1)),
      throwsA(isA<PluginManifestException>()),
    );
    expect(
      () => PluginManifest.parse('not: [valid'),
      throwsA(isA<PluginManifestException>()),
    );
    expect(manager.plugins, hasLength(6));
  });

  test('HTTP 只在匹配后请求；保留事件上下文，不泄露 QQ 凭据或插件密钥到请求体', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <Map<String, dynamic>>[];
    final authorizations = <String?>[];
    server.listen((request) async {
      authorizations.add(
        request.headers.value(HttpHeaders.authorizationHeader),
      );
      final data =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(data);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'reply': '```text\n${data['text']}\n```'}),
      );
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}/qqbot');
    final manager = await pluginManager(MemoryStorage(config: validConfig()));
    final definition = httpExample(endpoint);
    final info = await manager.installPlugin(jsonEncode(definition));
    expect(await manager.enablePlugin(info.id), false);
    expect(manager.errorFor(info.id), contains('插件服务令牌'));
    await manager.updatePluginConfig(info.id, {
      'service_token': 'only-service-secret',
      'language': '中文',
    });
    await manager.enablePlugin(info.id);
    expect(requests, isEmpty);
    expect(await manager.processMessage(pluginEvent('/unknown')), isEmpty);
    expect(requests, isEmpty);
    final responses = await manager.processMessage(pluginEvent('/echo 多行\n内容'));
    expect(responses.single.content, contains('多行 内容'));
    expect(requests, hasLength(1));
    expect(authorizations.single, 'Bearer only-service-secret');
    expect(requests.single['schema_version'], 1);
    expect(requests.single['message']['message_id'], 'source-1');
    expect(requests.single['message']['session_id'], 'group-1');
    expect(requests.single['message']['is_group'], true);
    expect(requests.single['config'], {'language': '中文'});
    expect(jsonEncode(requests), isNot(contains('only-service-secret')));
    expect(jsonEncode(requests), isNot(contains('test-secret')));
    expect(jsonEncode(requests), isNot(contains('valid-token')));
    final exported = manager.exportPlugin(info.id);
    expect(exported, isNot(contains('only-service-secret')));
    expect(PluginManifest.parse(exported).id, info.id);
  });

  test('HTTP 禁止远程明文、URL 凭据、重定向及转发 secret 配置', () async {
    for (final url in [
      'http://example.com/qqbot',
      'https://user:password@example.com/qqbot',
      'https://example.com/qqbot?key=secret',
    ]) {
      expect(
        () => PluginManifest.parse(jsonEncode(httpExample(Uri.parse(url)))),
        throwsA(isA<PluginManifestException>()),
      );
    }
    final leaked = httpExample(Uri.parse('https://example.com/qqbot'));
    (leaked['http'] as Map)['send_config_keys'] = ['service_token'];
    expect(
      () => PluginManifest.parse(jsonEncode(leaked)),
      throwsA(isA<PluginManifestException>()),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var redirected = false;
    server.listen((request) async {
      if (request.uri.path == '/target') redirected = true;
      request.response.statusCode = 302;
      request.response.headers.set(
        'location',
        'http://127.0.0.1:${server.port}/target',
      );
      await request.response.close();
    });
    final manager = await pluginManager();
    final info = await manager.installPlugin(
      jsonEncode(
        httpExample(Uri.parse('http://127.0.0.1:${server.port}/qqbot')),
      ),
    );
    await manager.updatePluginConfig(info.id, {
      'service_token': 'hidden-token',
    });
    await manager.enablePlugin(info.id);
    expect(await manager.processMessage(pluginEvent('/echo hello')), isEmpty);
    expect(redirected, false);
    expect(manager.errorFor(info.id), contains('HTTP 302'));
    expect(manager.errorFor(info.id), isNot(contains('hidden-token')));
  });

  test('执行中卸载不会并发修改异常，也不会在卸载后返回迟到的回复', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<void>();
    final release = Completer<void>();
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      received.complete();
      await release.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"reply":"迟到回复"}');
      await request.response.close();
    });
    final manager = await pluginManager();
    final info = await manager.installPlugin(
      jsonEncode(
        httpExample(Uri.parse('http://127.0.0.1:${server.port}/qqbot')),
      ),
    );
    await manager.updatePluginConfig(info.id, {
      'service_token': 'test-service-token',
    });
    await manager.enablePlugin(info.id);
    final pending = manager.processMessage(pluginEvent('/echo hello'));
    await received.future;
    await manager.uninstallPlugin(info.id);
    release.complete();
    expect(await pending, isEmpty);
  });

  test('HTTP 响应超限会被拒绝，清单导出清空密钥默认值', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(jsonEncode({'reply': 'x' * 70000}));
      await request.response.close();
    });
    final manager = await pluginManager();
    final raw = httpExample(Uri.parse('http://127.0.0.1:${server.port}/qqbot'));
    (raw['config'] as Map)['service_token'] = 'default-secret-must-not-export';
    final definition = PluginManifest.parse(jsonEncode(raw));
    expect(
      definition.exportDefinition(),
      isNot(contains('default-secret-must-not-export')),
    );
    final info = await manager.installPlugin(jsonEncode(raw));
    await manager.enablePlugin(info.id);
    expect(await manager.processMessage(pluginEvent('/echo hello')), isEmpty);
    expect(manager.errorFor(info.id), contains('64 KB'));
  });

  test('HTTP 总超时会关闭等待，不泄露服务令牌', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    // 接收请求但不响应，用真实回环连接验证超时和关闭行为。
    server.listen((request) async {
      await request.drain<void>();
    });
    final manager = await pluginManager();
    final raw = httpExample(Uri.parse('http://127.0.0.1:${server.port}/qqbot'));
    (raw['http'] as Map)['timeout_ms'] = 1000;
    final info = await manager.installPlugin(jsonEncode(raw));
    await manager.updatePluginConfig(info.id, {
      'service_token': 'timeout-fixture-token',
    });
    await manager.enablePlugin(info.id);
    expect(
      await manager
          .processMessage(pluginEvent('/echo hello'))
          .timeout(const Duration(seconds: 5)),
      isEmpty,
    );
    expect(manager.errorFor(info.id), contains('超时'));
    expect(manager.errorFor(info.id), isNot(contains('timeout-fixture-token')));
  });
}
