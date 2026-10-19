import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/services/websocket_service.dart';

class LocalGateway {
  final HttpServer server;
  final sockets = <WebSocket>[];
  final payloads = <Map<String, dynamic>>[];
  final int heartbeatMs;
  bool sendReady = true;
  bool acknowledgeHeartbeat = true;

  LocalGateway._(this.server, this.heartbeatMs);

  static Future<LocalGateway> start({int heartbeatMs = 45000}) async {
    final gateway = LocalGateway._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      heartbeatMs,
    );
    gateway.server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      gateway.sockets.add(socket);
      socket.add(
        jsonEncode({
          'op': 10,
          'd': {'heartbeat_interval': gateway.heartbeatMs},
        }),
      );
      socket.listen((data) {
        final payload = jsonDecode(data as String) as Map<String, dynamic>;
        gateway.payloads.add(payload);
        if (payload['op'] == 2 && gateway.sendReady) gateway.ready(socket);
        if (payload['op'] == 6) {
          socket.add(jsonEncode({'op': 0, 't': 'RESUMED', 's': 8, 'd': ''}));
        }
        if (payload['op'] == 1 && gateway.acknowledgeHeartbeat) {
          socket.add(jsonEncode({'op': 11}));
        }
      });
    });
    return gateway;
  }

  String get url => 'ws://127.0.0.1:${server.port}/gateway';

  void ready(WebSocket socket) => socket.add(
    jsonEncode({
      'op': 0,
      't': 'READY',
      's': 1,
      'd': {
        'session_id': 'gateway-session',
        'user': {'id': 'bot-id', 'username': '测试机器人'},
      },
    }),
  );

  void event(String type, Map<String, dynamic> data, {int seq = 7}) =>
      sockets.last.add(
        jsonEncode({'op': 0, 's': seq, 't': type, 'id': 'event-id', 'd': data}),
      );

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

Future<void> until(bool Function() check) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!check()) {
    if (DateTime.now().isAfter(deadline)) fail('等待本地网关事件超时');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late WebSocketService service;
  late LocalGateway gateway;

  setUp(() {
    service = WebSocketService();
  });
  tearDown(() async {
    service.dispose();
    await gateway.close();
  });

  test('只有 READY 鉴权完成才在线，订阅群聊和单聊的官方 Intent', () async {
    gateway = await LocalGateway.start();
    gateway.sendReady = false;
    final connecting = service.connect(
      wsUrl: gateway.url,
      accessToken: 'test-token',
      autoReconnect: false,
    );
    await until(() => gateway.payloads.any((p) => p['op'] == 2));
    expect(service.isConnected, isFalse);
    expect(gateway.payloads.single['d']['token'], 'QQBot test-token');
    expect(
      gateway.payloads.single['d']['intents'],
      (1 << 24) | (1 << 25) | (1 << 26),
    );
    gateway.ready(gateway.sockets.single);
    expect(await connecting, isTrue);
    expect(service.isConnected, isTrue);
  });

  test('单聊读取 author.user_openid，图片附件被识别并补全 HTTPS 地址', () async {
    gateway = await LocalGateway.start();
    await service.connect(
      wsUrl: gateway.url,
      accessToken: 'test-token',
      autoReconnect: false,
    );
    final received = service.messageStream.first;
    gateway.event('C2C_MESSAGE_CREATE', {
      'id': 'message-id',
      'author': {'user_openid': 'user-openid'},
      'content': '',
      'timestamp': '2026-10-15T12:00:00+08:00',
      'attachments': [
        {'url': 'https://example.com/file.txt', 'content_type': 'file'},
        {'url': '//example.com/image.png', 'content_type': 'image/png'},
      ],
    });
    final message = await received;
    expect(message['sessionId'], 'user-openid');
    expect(message['senderId'], 'user-openid');
    expect(message['imageUrl'], 'https://example.com/image.png');
    expect(message['messageType'], 7);
    expect(message['eventId'], 'event-id');
  });

  test('断线后使用新凭证和原 Session 恢复，RESUMED 的空字符串载荷可处理', () async {
    gateway = await LocalGateway.start();
    await service.connect(
      wsUrl: gateway.url,
      accessToken: 'old-token',
      reconnectInterval: const Duration(milliseconds: 30),
    );
    final received = service.messageStream.first;
    gateway.event('GROUP_AT_MESSAGE_CREATE', {
      'id': 'group-message',
      'group_openid': 'group-id',
      'author': {'member_openid': 'member-id'},
      'content': '你好',
    });
    await received;
    service.refreshAccessToken = () async => 'new-token';
    await gateway.sockets.first.close();
    await until(
      () => gateway.payloads.any((p) => p['op'] == 6) && service.isConnected,
    );
    final resume = gateway.payloads.firstWhere((p) => p['op'] == 6);
    expect(resume['d'], {
      'token': 'QQBot new-token',
      'session_id': 'gateway-session',
      'seq': 7,
    });
  });

  test('群成员头像和群资料字段不会在规范化事件时被置空或互相混用', () async {
    gateway = await LocalGateway.start();
    await service.connect(wsUrl: gateway.url, accessToken: 'token');
    final received = service.messageStream.first;
    gateway.event('GROUP_MESSAGE_CREATE', {
      'id': 'metadata',
      'group_openid': 'g',
      'group_name': '官方群',
      'group_avatar': 'https://example.com/group.png',
      'author': {
        'member_openid': 'm',
        'username': '小明',
        'avatar': 'https://example.com/member.png',
      },
      'content': '你好',
    });
    final message = await received;
    expect(message['senderName'], '小明');
    expect(message['senderAvatarUrl'], 'https://example.com/member.png');
    expect(message['groupName'], '官方群');
    expect(message['groupAvatarUrl'], 'https://example.com/group.png');
  });

  test('主动断开后不会被旧连接的关闭回调重新连上', () async {
    gateway = await LocalGateway.start();
    await service.connect(
      wsUrl: gateway.url,
      accessToken: 'token',
      reconnectInterval: const Duration(milliseconds: 20),
    );
    service.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.state, ConnectionState.disconnected);
    expect(gateway.sockets, hasLength(1));
  });

  test('心跳以毫秒计时，无 ACK 时检测断线', () async {
    gateway = await LocalGateway.start(heartbeatMs: 80);
    gateway.acknowledgeHeartbeat = false;
    await service.connect(
      wsUrl: gateway.url,
      accessToken: 'token',
      autoReconnect: false,
    );
    await until(() => gateway.payloads.any((p) => p['op'] == 1));
    await until(() => service.state == ConnectionState.disconnected);
    expect(service.lastError, contains('心跳超时'));
  });
}
