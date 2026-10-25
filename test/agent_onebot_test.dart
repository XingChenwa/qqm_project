import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/onebot.dart';

Future<void> waitFor(bool Function() predicate) async {
  for (var i = 0; i < 300; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('OneBot condition did not become true');
}

void respond(WebSocket socket, {String self = '10001', List<Json>? requests}) {
  socket.listen((raw) {
    final value = object(jsonDecode(raw as String));
    requests?.add(value);
    if (value['action'] == 'no_reply') return;
    socket.add(
      jsonEncode({
        'status': value['action'] == 'fail' ? 'failed' : 'ok',
        'retcode': value['action'] == 'fail' ? 1403 : 0,
        'echo': value['echo'],
        'data': value['action'] == 'get_login_info'
            ? {'user_id': self, 'nickname': '模拟协议端'}
            : {'message_id': 42},
      }),
    );
  });
}

void main() {
  test('反向根路径支持短令牌与本机无令牌，监听后可以完整收发', () async {
    for (final token in ['', 'short']) {
      final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserve.port;
      await reserve.close();
      final transport = OneBotTransport(
        AgentConnection(
          id: 'root',
          name: 'Root',
          selfId: '10001',
          mode: 'reverse',
          port: port,
          path: '/',
          token: token,
        ),
      );
      WebSocket? peer;
      try {
        await transport.start();
        peer = await WebSocket.connect(
          'ws://127.0.0.1:$port/',
          headers: {
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            'X-Self-ID': '10001',
            'X-Client-Role': 'Universal',
          },
        );
        respond(peer);
        await waitFor(() => transport.connected);
        expect(
          (await transport.call('send_group_msg', {
            'group_id': 20002,
            'message': [textSegment('root')],
          }))['message_id'],
          42,
        );
      } finally {
        await transport.stop();
        await peer?.close();
      }
    }
    expect(
      () => AgentConnection(
        id: 'public',
        name: 'Public',
        selfId: '10001',
        mode: 'reverse',
        host: '0.0.0.0',
      ).validate(),
      throwsA(isA<AgentException>()),
    );
  });
  test('正向 WS 校验账号、Bearer 鉴权、echo 回执及事件过滤', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    WebSocket? protocol;
    String? auth;
    final requests = <Json>[];
    server.listen((r) async {
      auth = r.headers.value('authorization');
      protocol = await WebSocketTransformer.upgrade(r);
      respond(protocol!, requests: requests);
    });
    final transport = OneBotTransport(
      AgentConnection(
        id: 'one',
        name: 'One',
        selfId: '10001',
        url: 'ws://127.0.0.1:${server.port}/',
        token: 'fixture-token',
      ),
    );
    final events = <Json>[];
    transport.onEvent = events.add;
    try {
      await transport.start();
      await waitFor(() => transport.connected);
      expect(auth, 'Bearer fixture-token');
      expect(transport.nickname, '模拟协议端');
      final result = await transport.call('send_group_msg', {
        'group_id': 20002,
        'message': [textSegment('hello')],
      });
      expect(result['message_id'], 42);
      expect(requests.last['echo'], isNotEmpty);
      protocol!.add(jsonEncode({'post_type': 'message', 'self_id': 99999}));
      protocol!.add(jsonEncode({'post_type': 'message', 'self_id': 10001}));
      await waitFor(() => events.isNotEmpty);
      expect(events, hasLength(1));
      await expectLater(transport.call('fail'), throwsA(isA<AgentException>()));
    } finally {
      await transport.stop();
      await protocol?.close();
      await server.close(force: true);
    }
  });
  test('账号不匹配不接受事件，不允许自动发送', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    WebSocket? peer;
    server.listen((r) async {
      peer = await WebSocketTransformer.upgrade(r);
      respond(peer!, self: '99999');
    });
    final transport = OneBotTransport(
      AgentConnection(
        id: 'a',
        name: 'a',
        selfId: '10001',
        url: 'ws://127.0.0.1:${server.port}/',
      ),
    );
    try {
      await transport.start();
      await waitFor(() => transport.status.contains('校验失败'));
      expect(transport.connected, isFalse);
      expect(
        () => transport.call('send_private_msg'),
        throwsA(isA<AgentException>()),
      );
    } finally {
      await transport.stop();
      await peer?.close();
      await server.close(force: true);
    }
  });
  for (final split in [false, true]) {
    test('反向 WS ${split ? 'API/Event 双连接' : 'Universal'} 鉴权、账号和完整收发', () async {
      final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserve.port;
      await reserve.close();
      const token = 'fixture-token-16chars';
      final transport = OneBotTransport(
        AgentConnection(
          id: 'reverse',
          name: 'reverse',
          selfId: '10001',
          mode: 'reverse',
          port: port,
          token: token,
        ),
      );
      final sockets = <WebSocket>[], events = <Json>[];
      transport.onEvent = events.add;
      try {
        await transport.start();
        expect(transport.connected, isFalse);
        final url = 'ws://127.0.0.1:$port/onebot/v11';
        await expectLater(
          WebSocket.connect(
            url,
            headers: {
              'Authorization': 'Bearer incorrect',
              'X-Self-ID': '10001',
            },
          ),
          throwsA(isA<WebSocketException>()),
        );
        await expectLater(
          WebSocket.connect(
            url,
            headers: {'Authorization': 'Bearer $token', 'X-Self-ID': '99999'},
          ),
          throwsA(isA<WebSocketException>()),
        );
        await expectLater(
          WebSocket.connect(
            url,
            headers: {
              'Authorization': 'Bearer $token',
              'X-Self-ID': '10001',
              'Origin': 'https://hostile.example',
            },
          ),
          throwsA(isA<WebSocketException>()),
        );
        final api = await WebSocket.connect(
          split ? '$url/api' : url,
          headers: {
            'Authorization': 'Bearer $token',
            'X-Self-ID': '10001',
            'X-Client-Role': split ? 'API' : 'Universal',
          },
        );
        sockets.add(api);
        respond(api);
        WebSocket event = api;
        if (split) {
          event = await WebSocket.connect(
            '$url/event',
            headers: {
              'Authorization': 'Bearer $token',
              'X-Self-ID': '10001',
              'X-Client-Role': 'Event',
            },
          );
          sockets.add(event);
          event.listen((_) {});
        }
        await waitFor(() => transport.connected);
        expect(
          (await transport.call('send_private_msg', {
            'user_id': 20002,
          }))['message_id'],
          42,
        );
        event.add(jsonEncode({'post_type': 'message', 'self_id': 10001}));
        await waitFor(() => events.length == 1);
        await event.close();
        await waitFor(() => !transport.connected);
      } finally {
        await transport.stop();
        for (final s in sockets) {
          await s.close();
        }
      }
    });
  }
  test('超时不重发，停止时完成未决请求且关闭监听端口', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    WebSocket? peer;
    final requests = <Json>[];
    server.listen((r) async {
      peer = await WebSocketTransformer.upgrade(r);
      respond(peer!, requests: requests);
    });
    final transport = OneBotTransport(
      AgentConnection(
        id: 'one',
        name: 'one',
        selfId: '10001',
        url: 'ws://127.0.0.1:${server.port}/',
      ),
      callTimeout: const Duration(milliseconds: 300),
    );
    try {
      await transport.start();
      await waitFor(() => transport.connected);
      await expectLater(
        transport.call('no_reply'),
        throwsA(isA<AgentException>()),
      );
      expect(requests.where((r) => r['action'] == 'no_reply'), hasLength(1));
      final pending = expectLater(
        transport.call('no_reply'),
        throwsA(isA<AgentException>()),
      );
      await transport.stop();
      await pending;
    } finally {
      await transport.stop();
      await peer?.close();
      await server.close(force: true);
    }
  });
  test('正向重定向不转发令牌', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var targetCalls = 0;
    server.listen((r) async {
      if (r.uri.path == '/target') targetCalls++;
      r.response.statusCode = 302;
      r.response.headers.set('location', '/target');
      await r.response.close();
    });
    final transport = OneBotTransport(
      AgentConnection(
        id: 'a',
        name: 'a',
        selfId: '10001',
        url: 'ws://127.0.0.1:${server.port}/',
        token: 'fixture',
      ),
    );
    try {
      await transport.start();
      expect(targetCalls, 0);
      expect(transport.connected, isFalse);
    } finally {
      await transport.stop();
      await server.close(force: true);
    }
  });
}
