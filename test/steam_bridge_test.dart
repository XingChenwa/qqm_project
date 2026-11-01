import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_service_dispatcher.dart';
import 'package:qq_bot_manager/core/plugins/bridge_plugin.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';
import 'package:qq_bot_manager/models/outgoing_message.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/utils/inline_image.dart';

import 'support/fakes.dart';

Map<String, dynamic> steamManifest() =>
    jsonDecode(File('test/fixtures/legacy_bridge.json').readAsStringSync())
        as Map<String, dynamic>;

class ConnectedGateway extends TestGateway {
  @override
  bool get isConnected => true;
}

class InlineMediaAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(
        options.path.endsWith('/files')
            ? {'file_info': 'fixture-file-info'}
            : {'id': 'fixture-platform-id'},
      ),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // All real sockets in this file are synthetic loopback fixture servers.
  HttpOverrides.global = null;
  test('原版图片字节直接上传 QQ，发送 file_info，拒绝伪装图片', () async {
    final adapter = InlineMediaAdapter();
    final api = ApiService(dio: Dio()..httpClientAdapter = adapter);
    final bytes = img.encodePng(img.Image(width: 4, height: 4));
    final source = 'data:image/png;base64,${base64Encode(bytes)}';
    final result = await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'fixture-token',
      targetId: 'fixture-group',
      isGroup: true,
      message: OutgoingMessage(type: 7, mediaSource: source),
    );
    expect(result.data, 'fixture-platform-id');
    expect(adapter.requests.length, 2);
    expect(adapter.requests.first.data['file_data'], base64Encode(bytes));
    expect(adapter.requests.first.data.containsKey('url'), isFalse);
    expect(
      adapter.requests.last.data['media']['file_info'],
      'fixture-file-info',
    );
    final bad = await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'fixture-token',
      targetId: 'fixture-group',
      isGroup: true,
      message: const OutgoingMessage(
        type: 7,
        mediaSource: 'data:image/png;base64,AAAA',
      ),
    );
    expect(bad.isSuccess, isFalse);
    expect(adapter.requests.length, 2);
  });
  test('Steam 清单导入默认停用，令牌与 API Key 为独立密钥配置', () {
    final definition = PluginManifest.parse(jsonEncode(steamManifest()));
    expect(definition.toInfo().isEnabled, isFalse);
    expect(definition.secretKeys, {'service_token', 'steam_api_key'});
    expect(definition.http['send_secret_keys'], ['steam_api_key']);
    expect(
      definition.permissions,
      containsAll(['group:members', 'message:recall']),
    );
  });

  test('禁止通过普通 HTTP 协议发送密钥、未知密钥或服务鉴权令牌', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (m) => (m['http'] as Map).remove('protocol'),
      (m) => m['http']['send_secret_keys'] = ['service_token'],
      (m) => m['http']['send_secret_keys'] = ['clientSecret'],
      (m) => m['http']['send_config_keys'] = ['steam_api_key'],
      (m) => m['http']['url'] = 'https://example.com/redirect?token=secret',
      (m) => m['http']['poll_interval_ms'] = 20,
    ]) {
      final value = steamManifest();
      mutate(value);
      expect(
        () => PluginManifest.parse(jsonEncode(value)),
        throwsA(isA<PluginManifestException>()),
      );
    }
  });

  test('排队命令占用本轮处理并遵守同用户冷却，不连续提交两次', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var submitted = 0;
    final subscription = server.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == '/v1/message') submitted++;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":true}');
      await request.response.close();
    });
    final storage = MemoryStorage(config: validConfig());
    storage.selectChatAccount('fixture-app');
    final manager = TestPluginManager(storage);
    try {
      await manager.init();
      final manifest = steamManifest();
      manifest['http']['url'] = 'http://127.0.0.1:${server.port}';
      manifest['config'] = {'service_token': 'fixture-service-token'};
      await manager.installPlugin(jsonEncode(manifest));
      expect(await manager.enablePlugin('steam_bridge'), isTrue);
      final message = PluginMessage(
        messageId: 'queued',
        sessionId: 'group',
        senderId: 'user',
        senderName: '测试',
        content: '/steam帮助',
        messageType: 0,
        isGroup: true,
        timestamp: DateTime.now(),
      );
      expect(await manager.processMessage(message), isEmpty);
      expect(await manager.processMessage(message), isEmpty);
      expect(submitted, 1);
      await manager.disablePlugin('steam_bridge');
    } finally {
      manager.dispose();
      await server.close(force: true);
      await subscription.cancel();
    }
  });

  test('原工作台桥接队列：真实发送结果确认、ACK 丢失去重、停用后停止轮询', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final manifest = steamManifest();
    manifest['http']['url'] = 'http://127.0.0.1:${server.port}';
    manifest['http']['poll_interval_ms'] = 30000;
    final definition = PluginManifest.parse(jsonEncode(manifest));
    final info = definition.toInfo();
    info.config.addAll({
      'service_token': 'fixture-service-token',
      'steam_api_key': 'fixture-steam-key',
    });
    final plugin = BridgePlugin(info, definition);
    var appId = 'app-A';
    var sent = 0;
    var polls = 0;
    var ack = 0;
    final bodies = <Map<String, dynamic>>[];
    final outbox = <String, dynamic>{
      'id': 'envelope-A',
      'app_id': appId,
      'action': 'send',
      'target_id': 'group',
      'is_group': true,
      'format': 'text',
      'content': 'Steam 查询结果',
      'reply_to_message_id': 'inbound',
    };
    final subscription = server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer fixture-service-token',
      );
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      bodies.add(body);
      var result = <String, dynamic>{'ok': true};
      if (request.uri.path == '/v1/poll') {
        polls++;
        result = {
          'ok': true,
          'ready': true,
          'messages': [outbox],
        };
      } else if (request.uri.path == '/v1/ack') {
        ack++;
        expect(body['result']['message_id'], 'actual-platform-id');
        if (ack == 1) {
          request.response.statusCode = 503;
        }
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    });
    var data = <String, dynamic>{};
    plugin.host = PluginHost(
      store: () => PluginStore(() async => data, (value) async {
        data = value;
      }),
      help: () => '',
      appId: () => appId,
      currentAppId: () => appId,
      serviceReady: () => true,
      serviceRequest: (value) async {
        sent++;
        return {'ok': true, 'message_id': 'actual-platform-id'};
      },
    );
    try {
      await plugin.onEnable();
      final result = await plugin.execute(
        PluginMessage(
          messageId: 'inbound',
          sessionId: 'group',
          senderId: 'user',
          senderName: '测试',
          content: '/steam帮助',
          messageType: 0,
          isGroup: true,
          isFullGroupMessage: true,
          timestamp: DateTime.now(),
        ),
      );
      expect(result?.format, 'deferred');
      final submitted = bodies.first;
      expect(submitted['config']['steam_api_key'], 'fixture-steam-key');
      expect(jsonEncode(submitted), isNot(contains('fixture-service-token')));
      expect(submitted['app_id'], 'app-A');
      await plugin.onTick();
      await plugin.onTick();
      expect(sent, 1, reason: '丢失 ACK 不能重复发送到 QQ');
      expect(ack, 2);
      appId = 'app-B';
      await plugin.onTick();
      expect(sent, 1, reason: '旧 AppID 的队列不能在新 AppID 下发送');
      await plugin.onDisable();
      final last = polls;
      await plugin.onTick();
      expect(polls, last);
      appId = 'app-A';
      await plugin.onEnable();
      await plugin.onTick();
      expect(sent, 1, reason: '重新启用从插件本地数据恢复发送确认，避免再次发送');
    } finally {
      await plugin.onDisable();
      await server.close(force: true);
      await subscription.cancel();
    }
  });

  test('后台桥接只发送当前 AppID 已存在会话；真实消息 ID 和平台错误回传', () async {
    final storage = MemoryStorage(config: validConfig());
    final api = RecordingApi();
    final bot = BotClient(
      storage,
      apiService: api,
      webSocketService: ConnectedGateway(),
    );
    addTearDown(bot.dispose);
    final source = incoming(
      'steam-source',
    ).copyWith(extra: {'isGroup': true, 'botAppId': bot.config.appId});
    await storage.saveMessage(source);
    await storage.saveSession(
      ChatSession(
        id: source.sessionId,
        name: '测试群',
        sessionType: 1,
        lastMessageTime: DateTime.now(),
      ),
    );
    final host = PluginServiceDispatcher(bot, storage);
    final request = <String, dynamic>{
      'app_id': bot.config.appId,
      'action': 'send',
      'target_id': source.sessionId,
      'is_group': true,
      'reply_to_message_id': source.id,
      'format': 'text',
      'content': '测试查询结果',
      'proactive': false,
    };
    expect(
      (await host.dispatch({...request, 'app_id': 'other-app'}))['ok'],
      isFalse,
    );
    expect(
      (await host.dispatch({...request, 'target_id': 'unknown-group'}))['ok'],
      isFalse,
    );
    expect(
      (await host.dispatch({
        ...request,
        'reply_to_message_id': 'missing',
      }))['ok'],
      isFalse,
    );
    expect(api.calls, isEmpty);
    final result = await host.dispatch(request);
    expect(result, {'ok': true, 'message_id': 'sent-1'});
    expect(api.calls.single['msgId'], source.id);
    expect(api.calls.single['msgSeq'], 1);
    api.failSend = true;
    expect((await host.dispatch(request))['ok'], isFalse);
    expect(api.calls.last['msgSeq'], 2);
    final recalled = await host.dispatch({
      ...request,
      'action': 'recall',
      'message_id': source.id,
    });
    expect(recalled['ok'], isFalse, reason: '服务不能撤回群友消息');
  });

  test('超时被动回复不能变成主动消息，未知媒体与非法数据拒绝', () async {
    final storage = MemoryStorage(config: validConfig());
    final api = RecordingApi();
    final bot = BotClient(
      storage,
      apiService: api,
      webSocketService: ConnectedGateway(),
    );
    addTearDown(bot.dispose);
    final source = incoming(
      'old',
      timestamp: DateTime.now().subtract(const Duration(minutes: 6)),
    );
    await storage.saveMessage(source);
    await storage.saveSession(
      ChatSession(
        id: source.sessionId,
        name: '测试群',
        sessionType: 1,
        lastMessageTime: DateTime.now(),
      ),
    );
    final host = PluginServiceDispatcher(bot, storage);
    final request = <String, dynamic>{
      'app_id': bot.config.appId,
      'action': 'send',
      'target_id': source.sessionId,
      'is_group': true,
      'reply_to_message_id': source.id,
      'format': 'text',
      'content': '结果',
    };
    expect((await host.dispatch(request))['ok'], isFalse);
    expect(api.calls, isEmpty);
    expect(
      (await host.dispatch({
        ...request,
        'proactive': true,
        'format': 'media',
        'media_type': 1,
        'mime': 'image/svg+xml',
        'media_base64': 'AAAA',
      }))['ok'],
      isFalse,
    );
    expect(
      () => inlineImageBytes('data:image/svg+xml;base64,AAAA'),
      throwsFormatException,
    );
  });
}
