import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:image/image.dart' as image;
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/ai.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/qqbot.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/audio.dart';
import 'agent_audio_test.dart' show sampleWav;

class LocalModel implements AgentModel {
  final requests = <Json>[];
  @override
  Future<Json> complete(
    AgentProvider provider,
    Json request,
    CancelToken cancel,
  ) async {
    requests.add(request);
    return {
      'choices': [
        {
          'message': {'content': '独立 QQBot AI 回复'},
        },
      ],
    };
  }
}

class QqFixture {
  late HttpServer server;
  WebSocket? socket;
  final bodies = <Json>[];
  final identifies = <Json>[];
  final profilePaths = <String>[];
  final sendFailures = <Json>[];
  Completer<void>? profileGate;
  bool denyProfiles = false;
  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');
  Future<void> open() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      if (WebSocketTransformer.isUpgradeRequest(r)) {
        socket = await WebSocketTransformer.upgrade(r);
        socket!.listen((raw) {
          final frame = object(jsonDecode(raw as String));
          if (frame['op'] == 2) {
            identifies.add(frame);
            socket!.add(
              jsonEncode({
                'op': 0,
                't': 'READY',
                's': 1,
                'd': {
                  'session_id': 'fixture-session',
                  'user': {'id': 'BOT_OPENID', 'username': '官方测试助手'},
                },
              }),
            );
          }
          if (frame['op'] == 1) socket!.add(jsonEncode({'op': 11}));
        });
        socket!.add(
          jsonEncode({
            'op': 10,
            'd': {'heartbeat_interval': 60000},
          }),
        );
        return;
      }
      r.response.headers.contentType = ContentType.json;
      final Json body = r.method == 'POST'
          ? object(jsonDecode(await utf8.decoder.bind(r).join()))
          : {};
      if (r.uri.path == '/app/getAppAccessToken') {
        expect(body, {'appId': '10000001', 'clientSecret': 'fixture-secret'});
        r.response.write(
          jsonEncode({
            'access_token': 'fixture-access-token',
            'expires_in': 7200,
          }),
        );
      } else {
        expect(r.headers.value('authorization'), 'QQBot fixture-access-token');
        if (r.uri.path == '/gateway') {
          r.response.write(
            jsonEncode({'url': 'ws://127.0.0.1:${server.port}/gateway-ws'}),
          );
        } else if (r.method == 'GET' && r.uri.path.endsWith('/info')) {
          profilePaths.add(r.uri.path);
          await profileGate?.future;
          if (denyProfiles) {
            r.response.statusCode = 403;
            r.response.write(jsonEncode({'code': 11253}));
            await r.response.close();
            return;
          }
          r.response.write(
            jsonEncode({'group_openid': 'GROUP_OPENID', 'group_name': '官方测试群'}),
          );
        } else if (r.method == 'GET' && r.uri.path.contains('/members/')) {
          profilePaths.add(r.uri.path);
          await profileGate?.future;
          if (denyProfiles) {
            r.response.statusCode = 403;
            r.response.write(jsonEncode({'code': 11253}));
            await r.response.close();
            return;
          }
          r.response.write(
            jsonEncode({
              'member_openid': r.uri.pathSegments.last,
              'username': '官方测试成员',
            }),
          );
        } else {
          bodies.add({'path': r.uri.path, ...body});
          if (r.uri.path.endsWith('/messages') && sendFailures.isNotEmpty) {
            r.response.statusCode = 400;
            r.response.headers.set('x-tps-trace-id', 'fixture-trace-id');
            r.response.write(jsonEncode(sendFailures.removeAt(0)));
            await r.response.close();
            return;
          }
          r.response.write(
            jsonEncode(
              r.uri.path.endsWith('/files')
                  ? {'file_info': 'fixture-uploaded-image'}
                  : {'id': 'out-${bodies.length}'},
            ),
          );
        }
      }
      await r.response.close();
    });
  }

  void message(
    String id, {
    String type = 'GROUP_AT_MESSAGE_CREATE',
    String content = '/ai 你好',
    DateTime? time,
    Json? author,
    Json extra = const {},
  }) {
    socket!.add(
      jsonEncode({
        'op': 0,
        's': 10,
        't': type,
        'd': {
          'id': id,
          'group_openid': 'GROUP_OPENID',
          'author':
              author ??
              {
                'member_openid': 'MEMBER_OPENID',
                'user_openid': 'USER_OPENID',
                'username': '测试用户',
              },
          'content': content,
          'timestamp': (time ?? DateTime.now()).toIso8601String(),
          'message_scene': {
            'ext': ['msg_idx=REFIDX_$id'],
          },
          ...extra,
        },
      }),
    );
  }

  Future<void> close() async {
    await socket?.close();
    await server.close(force: true);
  }
}

Future<void> until(bool Function() check) async {
  for (var i = 0; i < 250; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('local QQBot fixture timed out');
}

void main() {
  late QqFixture fixture;
  late QqBotAgentTransport transport;
  final config = AgentConnection(
    id: 'official',
    name: 'QQBot Agent',
    selfId: '10000001',
    protocol: 'qqbot',
    clientSecret: 'fixture-secret',
  );
  setUp(() async {
    fixture = QqFixture();
    await fixture.open();
    transport = QqBotAgentTransport(
      config,
      apiBase: fixture.base,
      tokenEndpoint: fixture.base.resolve('/app/getAppAccessToken'),
    );
  });
  tearDown(() async {
    await transport.stop();
    await fixture.close();
  });
  test('真实本地 HTTP + 官方网关握手，群与单聊 OpenID 事件正确转换', () async {
    final events = <Json>[];
    transport.onEvent = events.add;
    await transport.start();
    expect(transport.connected, isTrue);
    expect(transport.nickname, '官方测试助手');
    expect(
      object(fixture.identifies.single['d'])['token'],
      'QQBot fixture-access-token',
    );
    fixture.message('group-1');
    fixture.message('user-1', type: 'C2C_MESSAGE_CREATE');
    await until(() => events.length == 2);
    expect(events[0]['group_id'], 'GROUP_OPENID');
    expect(events[0]['_mentioned'], isTrue);
    expect(events[1]['user_id'], 'USER_OPENID');
    expect(events[1]['message_type'], 'private');
    await transport.call('send_private_msg', {
      'user_id': 'USER_OPENID',
      'message': [textSegment('你好')],
    });
    expect(fixture.bodies.single['path'], '/v2/users/USER_OPENID/messages');
    expect(fixture.bodies.single['msg_id'], 'user-1');
  });
  test('官方图片补齐HTTPS且空WAV字段不覆盖原图，语音优先使用官方WAV', () async {
    final events = <Json>[];
    transport.onEvent = events.add;
    await transport.start();
    fixture.message(
      'attachments',
      extra: {
        'attachments': [
          {
            'content_type': 'image/jpeg',
            'filename': 'picture.jpg',
            'url': '//multimedia.fixture.test/download?rkey=fixture-picture',
            'voice_wav_url': '',
          },
          {
            'filename': 'no-mime.png',
            'width': 32,
            'height': 32,
            'url': '//multimedia.fixture.test/no-mime.png',
          },
          {
            'content_type': 'voice',
            'filename': 'voice.silk',
            'url': '//multimedia.fixture.test/voice.silk',
            'voice_wav_url': '//multimedia.fixture.test/voice.wav',
          },
        ],
      },
    );
    await until(() => events.isNotEmpty);
    final segments = (events.single['message'] as List).map(object).toList();
    final images = segments.where((s) => s['type'] == 'image').toList();
    expect(images, hasLength(2));
    expect(
      object(images.first['data'])['url'],
      'https://multimedia.fixture.test/download?rkey=fixture-picture',
    );
    expect(
      object(images.last['data'])['url'],
      'https://multimedia.fixture.test/no-mime.png',
    );
    final voice = segments.singleWhere((s) => s['type'] == 'record');
    expect(
      object(voice['data'])['url'],
      'https://multimedia.fixture.test/voice.wav',
    );
  });
  test('Markdown @、引用索引、并发回复序号、时限与跨群回复保护', () async {
    final events = <Json>[];
    transport.onEvent = events.add;
    await transport.start();
    fixture.message('source');
    await until(() => events.isNotEmpty);
    await transport.call('send_group_msg', {
      'group_id': 'GROUP_OPENID',
      'message': [
        {
          'type': 'reply',
          'data': {'id': 'source'},
        },
        {
          'type': 'at',
          'data': {'qq': 'MEMBER_OPENID'},
        },
        textSegment(' 你好'),
      ],
    });
    expect(fixture.bodies.single['msg_type'], 2);
    expect(
      object(fixture.bodies.single['markdown'])['content'],
      contains('<qqbot-at-user id="MEMBER_OPENID" />'),
    );
    expect(
      object(fixture.bodies.single['message_reference'])['message_id'],
      'REFIDX_source',
    );
    await Future.wait(
      List.generate(
        4,
        (_) => transport.call('send_group_msg', {
          'group_id': 'GROUP_OPENID',
          'message': [textSegment('并发回复')],
        }),
      ),
    );
    expect(fixture.bodies.map((b) => b['msg_seq']).toSet(), {1, 2, 3, 4, 5});
    await expectLater(
      transport.call('send_group_msg', {
        'group_id': 'GROUP_OPENID',
        'message': [textSegment('超额')],
      }),
      throwsA(isA<AgentException>()),
    );
    await expectLater(
      transport.call('send_group_msg', {
        'group_id': 'ANOTHER_GROUP',
        '_reply_id': 'source',
        'message': [textSegment('错误目标')],
      }),
      throwsA(isA<AgentException>()),
    );
    fixture.message(
      'expired',
      time: DateTime.now().subtract(const Duration(minutes: 6)),
    );
    await until(() => events.length == 2);
    await expectLater(
      transport.call('send_group_msg', {
        'group_id': 'GROUP_OPENID',
        '_reply_id': 'expired',
        'message': [textSegment('过期回复')],
      }),
      throwsA(isA<AgentException>()),
    );
    expect(fixture.bodies, hasLength(5));
  });
  test('官方事件自动触发 AI，OpenID 不转整数，配置快照不包含密钥', () async {
    final store = AgentStore.memory(), model = LocalModel();
    final agent = AgentController(
      store: store,
      model: model,
      transportFactory: (_) => transport,
    );
    try {
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
          name: '测试助手',
          prompt: '中文回复',
          providerId: 'model',
        ),
      );
      await agent.saveConnection(
        AgentConnection.fromJson({
          ...config.toJson(),
          'aiEnabled': true,
          'cooldownSeconds': 0,
        }),
      );
      await agent.connect('official');
      fixture.message('ai-trigger');
      await until(
        () => fixture.bodies.isNotEmpty && agent.busySessions.isEmpty,
      );
      final session = agent.sessions().single;
      expect(session.protocol, 'qqbot');
      expect(session.peerId, 'GROUP_OPENID');
      expect(fixture.bodies.single['msg_id'], 'ai-trigger');
      expect(fixture.bodies.single['content'], '独立 QQBot AI 回复');
      expect(agent.store.messages(session.key).last.source, 'ai');
      expect(jsonEncode(agent.snapshot()), isNot(contains('fixture-secret')));
      expect(jsonEncode(model.requests), isNot(contains('fixture-secret')));
      await expectLater(
        agent.syncContacts('official'),
        throwsA(isA<AgentException>()),
      );
      final other = AgentSession(
        connectionId: session.connectionId,
        selfId: session.selfId,
        kind: session.kind,
        peerId: session.peerId,
        name: session.name,
      );
      expect(other.key, isNot(session.key));
    } finally {
      await agent.shutdown();
      agent.dispose();
    }
  });
  test('持久化回复序号在重连后不回到 1', () async {
    final store = AgentStore.memory();
    await store.open();
    try {
      Future<int> reserve(String id, int limit) =>
          store.reserveReplySequence('qqbot-sequence:10000001:$id', limit);
      await transport.stop();
      for (var i = 0; i < 2; i++) {
        transport = QqBotAgentTransport(
          config,
          apiBase: fixture.base,
          tokenEndpoint: fixture.base.resolve('/app/getAppAccessToken'),
          reserveSequence: reserve,
        );
        final events = <Json>[];
        transport.onEvent = events.add;
        await transport.start();
        fixture.message('same-message');
        await until(() => events.isNotEmpty);
        await transport.call('send_group_msg', {
          'group_id': 'GROUP_OPENID',
          'message': [textSegment('回复')],
        });
        await transport.stop();
      }
      expect(fixture.bodies.map((b) => b['msg_seq']).toList(), [1, 2]);
    } finally {
      await store.close();
    }
  });
  test('QQBot Skill 图片上传与消息发送使用独立凭据，等待图片回执', () async {
    final received = <Json>[];
    transport.onEvent = received.add;
    await transport.start();
    fixture.message('image-trigger');
    await until(() => received.isNotEmpty);
    final bytes = image.encodePng(image.Image(width: 4, height: 4));
    final result = await transport.call('send_group_msg', {
      'group_id': 'GROUP_OPENID',
      '_reply_id': 'image-trigger',
      'message': [
        {
          'type': 'image',
          'data': {
            'file': 'base64://${base64Encode(bytes)}',
            'name': 'fixture.png',
          },
        },
      ],
    });
    expect(result['message_id'], isNotEmpty);
    expect(fixture.bodies, hasLength(2));
    expect(fixture.bodies.first['path'], '/v2/groups/GROUP_OPENID/files');
    expect(fixture.bodies.first['srv_send_msg'], false);
    expect(fixture.bodies.first['file_data'], base64Encode(bytes));
    expect(fixture.bodies.last['msg_type'], 7);
    expect(fixture.bodies.last['media'], {
      'file_info': 'fixture-uploaded-image',
    });
    expect(fixture.bodies.last['msg_id'], 'image-trigger');
    expect(fixture.bodies.last['msg_seq'], 1);
  });
  test('QQBot语音使用真实WAV上传并确认富媒体回执，额度耗尽不再上传', () async {
    final received = <Json>[];
    transport.onEvent = received.add;
    await transport.start();
    fixture.message('audio-trigger');
    await until(() => received.isNotEmpty);
    final audio = AgentAudio(sampleWav());
    final result = await transport.call('send_group_msg', {
      'group_id': 'GROUP_OPENID',
      '_reply_id': 'audio-trigger',
      'message': [audio.segment],
    });
    expect(result['message_id'], isNotEmpty);
    expect(fixture.bodies.first['file_type'], 3);
    expect(fixture.bodies.first['file_name'], 'voice.wav');
    expect(fixture.bodies.first['file_data'], base64Encode(sampleWav()));
    expect(fixture.bodies.last['msg_type'], 7);
    expect(fixture.bodies.last['msg_seq'], 1);
    for (var i = 0; i < 4; i++) {
      await transport.call('send_group_msg', {
        'group_id': 'GROUP_OPENID',
        '_reply_id': 'audio-trigger',
        'message': [textSegment('余量测试')],
      });
    }
    final before = fixture.bodies.length;
    await expectLater(
      transport.call('send_group_msg', {
        'group_id': 'GROUP_OPENID',
        '_reply_id': 'audio-trigger',
        'message': [audio.segment],
      }),
      throwsA(isA<AgentException>()),
    );
    expect(fixture.bodies.length, before);
  });
}
