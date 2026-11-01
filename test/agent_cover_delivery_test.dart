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
import 'agent_core_test.dart' as fixture;
import 'support/remote_cover_package_fixture.dart';

const jobId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const keyFixture = 'not-a-real-cover-api-key';

class DeliveryHttp extends AgentHttp {
  bool completed = false, tooLarge = false, failRead = false;
  final actions = <String>[];
  Completer<void>? audioEntered, audioRelease;
  Json response(Json input) {
    final action = text(input['action']);
    actions.add(action);
    return switch (action) {
      'health' => {
        'ok': true,
        'features': ['cover-selection-v1'],
      },
      'audio' => {
        'ok': true,
        'selection': {'duration': 45, 'mode': 'chorus'},
        'audioBase64': base64Encode(audioFixture()),
      },
      _ => {
        'ok': true,
        'job': {
          'id': jobId,
          'type': 'cover',
          'status': completed ? 'completed' : 'queued',
          'voice_complete': !tooLarge,
        },
      },
    };
  }

  @override
  Future<dynamic> request(
    Uri uri, {
    String method = 'GET',
    Json? body,
    Map<String, String> headers = const {},
    Json? query,
    CancelToken? cancel,
    int timeoutSeconds = 60,
    int maxBytes = 1048576,
  }) async {
    expect(uri.toString(), 'https://gqu.uuze.cn/api/tool');
    expect(headers['Authorization'], 'Bearer $keyFixture');
    expect(body?['scope'], startsWith('qqm-zip:'));
    if (failRead) throw const AgentException('fixture read timeout');
    if (body?['action'] == 'audio' && audioRelease != null) {
      if (audioEntered?.isCompleted == false) audioEntered!.complete();
      await audioRelease!.future;
    }
    return response(body!);
  }

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
  }) async => (
    bytes: Uint8List.fromList(
      utf8.encode(jsonEncode(response(object(jsonDecode(body as String))))),
    ),
    status: 200,
    headers: {'content-type': 'application/json'},
  );
}

class DeliveryTransport extends fixture.FakeAgentTransport {
  String failure = '';
  int capacity = 5, voiceAttempts = 0;
  DeliveryTransport(super.config);
  @override
  int? replyCapacity(String kind, String peerId, String triggerId) => capacity;
  @override
  Future<dynamic> call(String action, [Json params = const {}]) async {
    if (action.startsWith('send_') &&
        jsonEncode(params['message']).contains('"record"')) {
      voiceAttempts++;
      if (failure == 'unknown') {
        throw const AgentException('fixture connection closed after send');
      }
      if (failure == 'rejected') {
        throw const AgentHttpException(
          'fixture permission denied',
          statusCode: 403,
        );
      }
    }
    return super.call(action, params);
  }
}

void main() {
  final native = Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] != null;
  group('翻唱完成后后台发送', () {
    late AgentController agent;
    late DeliveryHttp http;
    late fixture.FakeAgentModel model;
    late DeliveryTransport transport;
    late AgentExtension extension;
    late AgentConnection connection;
    late AgentSession session;
    late AgentMessage trigger;
    late String scope;

    Future<void> configure({bool official = false}) async {
      if (official) await agent.disconnect('qq');
      await agent.saveConnection(
        AgentConnection(
          id: 'qq',
          name: 'fixture',
          selfId: official ? '1904104647' : '10001',
          protocol: official ? 'qqbot' : 'onebot',
          clientSecret: official ? 'fixture-client-secret' : '',
          resolveOfficialProfiles: false,
          useOiapiNickname: false,
          presetId: 'cover',
          aiEnabled: false,
          cooldownSeconds: 0,
        ),
      );
      if (official || !agent.connected('qq')) await agent.connect('qq');
      connection = agent.connection('qq')!;
      session = await agent.openSession(
        'qq',
        'group',
        official ? 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' : '20002',
      );
      trigger = AgentMessage(
        id: 'ob:original-request',
        sessionKey: session.key,
        senderId: '30003',
        senderName: '小明',
        segments: [textSegment('用音色唱高潮，完成后发给我')],
      );
      await agent.store.append(trigger);
      scope =
          'qqm-zip:11111111-1111-4111-8111-111111111111|${connection.protocol}:${connection.selfId}|group:${session.peerId}';
    }

    setUp(() async {
      http = DeliveryHttp();
      model = fixture.FakeAgentModel();
      agent = AgentController(
        store: AgentStore.memory(),
        http: http,
        model: model,
        transportFactory: (c) => transport = DeliveryTransport(c),
      );
      await agent.initialize();
      await agent.importPackage(await remoteCoverPackageBytes());
      extension = agent.extensions.firstWhere(
        (e) => e.id == 'remote_rvc_cover',
      );
      await agent.saveExtension(
        extension.copyWith(enabled: true, settings: {'apiKey': keyFixture}),
      );
      extension = agent.extensions.firstWhere(
        (e) => e.id == 'remote_rvc_cover',
      );
      await agent.saveProvider(
        AgentProvider(
          id: 'cover-model',
          name: 'fixture',
          baseUrl: 'http://127.0.0.1:1/v1',
          model: 'fixture',
        ),
      );
      await agent.savePreset(
        AgentPreset(
          id: 'cover',
          name: 'fixture',
          prompt: '使用真实工具',
          providerId: 'cover-model',
          skillIds: [extension.id],
        ),
      );
      await configure();
    });
    tearDown(() async {
      await agent.shutdown();
      agent.dispose();
    });
    Future<Json> op(
      String action, {
      String? overrideScope,
      AgentMessage? message,
    }) => agent.coverDeliveryOperation(
      connection,
      agent.extensions.firstWhere((e) => e.id == extension.id),
      session,
      message ?? trigger,
      {'action': action, 'jobId': jobId, 'scope': overrideScope ?? scope},
    );
    Future<void> tick() => agent.processCoverDeliveries(
      now: DateTime.now().add(const Duration(minutes: 1)),
    );
    Json row() => agent.store.all('agent-cover-delivery').single;

    test('排队后无需新消息或AI调用，完成即自动发语音且不重复', () async {
      expect((await op('watch'))['registered'], true);
      await tick();
      expect(transport.voiceAttempts, 0);
      http.completed = true;
      await tick();
      expect(row()['state'], 'sent');
      expect(object(row()['receipt'])['message_id'], isNotEmpty);
      expect(transport.voiceAttempts, 1);
      await tick();
      expect((await op('send'))['alreadySent'], true);
      expect(transport.voiceAttempts, 1);
      expect(model.requests, isEmpty);
      expect(jsonEncode(row()), isNot(contains(keyFixture)));
    });

    test('手动发送与后台共用去重记录，手动成功后后台不会再发', () async {
      await op('watch');
      http.completed = true;
      final sent = await op('send');
      expect(sent['sent'], true);
      await tick();
      expect(transport.voiceAttempts, 1);
      expect(row()['state'], 'sent');
    });

    test('回执不明不自动补发，恢复时sending转uncertain', () async {
      await op('watch');
      http.completed = true;
      transport.failure = 'unknown';
      await tick();
      expect(row()['state'], 'uncertain');
      await tick();
      expect(transport.voiceAttempts, 1);
      await agent.store.put(text(row()['key']), {...row(), 'state': 'sending'});
      await agent.recoverCoverDeliveries();
      expect(row()['state'], 'uncertain');
      await expectLater(op('send'), throwsA(isA<AgentException>()));
    });

    test('重建控制器后恢复已持久化的待发送任务', () async {
      await op('watch');
      final data = await agent.store.exportAllData();
      await agent.shutdown();
      agent.dispose();
      final nextStore = AgentStore.memory();
      await nextStore.open();
      await nextStore.replaceAllData(data);
      http = DeliveryHttp()..completed = true;
      agent = AgentController(
        store: nextStore,
        http: http,
        model: model,
        transportFactory: (c) => transport = DeliveryTransport(c),
      );
      await agent.initialize();
      await agent.connect('qq');
      await tick();
      expect(row()['state'], 'sent');
      expect(transport.voiceAttempts, 1);
    });

    test('官机窗口过期会等待原提问者新消息，不假装已发', () async {
      await configure(official: true);
      transport.capacity = 0;
      await op('watch');
      http.completed = true;
      await tick();
      expect(row()['state'], 'waiting_message');
      expect(transport.voiceAttempts, 0);
      expect(http.actions, isNot(contains('audio')));
      final next = AgentMessage(
        id: 'ob:new-request',
        sessionKey: session.key,
        senderId: '30003',
        senderName: '小明',
        segments: [textSegment('好了吗，发给我')],
      );
      await agent.store.append(next);
      transport.capacity = 5;
      await tick();
      expect(row()['state'], 'sent');
      expect(transport.sent.last['_reply_id'], 'new-request');
    });

    test('官机明确拒绝后不重复用同一消息重试，新消息才继续', () async {
      await configure(official: true);
      await op('watch');
      http.completed = true;
      transport.failure = 'rejected';
      await tick();
      expect(row()['state'], 'waiting_message');
      await tick();
      expect(transport.voiceAttempts, 1);
      transport.failure = '';
      await agent.store.append(
        AgentMessage(
          id: 'ob:try-again',
          sessionKey: session.key,
          senderId: '30003',
          senderName: '小明',
          segments: [textSegment('发给我')],
        ),
      );
      await tick();
      expect(row()['state'], 'sent');
      expect(transport.voiceAttempts, 2);
    });

    test('只有明确开启主动发送，官机无回复窗口时才尝试发送', () async {
      await configure(official: true);
      transport.capacity = 0;
      final current = agent.extensions.firstWhere((e) => e.id == extension.id);
      await agent.saveExtension(
        current.copyWith(
          settings: {...current.settings, 'allowProactive': true},
        ),
      );
      await op('watch');
      http.completed = true;
      await tick();
      expect(row()['state'], 'sent');
      expect(transport.voiceAttempts, 1);
      expect(transport.sent.last.containsKey('_reply_id'), false);
    });

    test('取消时正好在下载音频也不会继续发出', () async {
      await op('watch');
      http.completed = true;
      http.audioEntered = Completer<void>();
      http.audioRelease = Completer<void>();
      final checking = tick();
      await http.audioEntered!.future;
      await op('cancel');
      http.audioRelease!.complete();
      await checking;
      expect(row()['state'], 'cancelled');
      expect(transport.voiceAttempts, 0);
    });

    test('关闭自动发送、停止连接和更换服务器都不会误发或泄露旧凭证', () async {
      await op('watch');
      http.completed = true;
      await agent.saveExtension(
        extension.copyWith(
          enabled: true,
          settings: {'apiKey': keyFixture, 'autoSend': false},
        ),
      );
      await tick();
      expect(transport.voiceAttempts, 0);
      await agent.saveExtension(
        extension.copyWith(
          enabled: true,
          settings: {
            'apiKey': keyFixture,
            'baseOrigin': 'https://other.example.com',
          },
        ),
      );
      http.actions.clear();
      await tick();
      expect(http.actions, isEmpty);
      expect(transport.voiceAttempts, 0);
      await agent.disconnect('qq');
      await tick();
      expect(transport.voiceAttempts, 0);
    });

    test('跨群伪造范围被拒绝，完整成品过大不会用试听替代', () async {
      await expectLater(
        op('watch', overrideScope: '$scope-other-group'),
        throwsA(isA<AgentException>()),
      );
      await op('watch');
      http.completed = true;
      http.tooLarge = true;
      await tick();
      expect(row()['state'], 'failed');
      expect(transport.voiceAttempts, 0);
    });

    test('ZIP原位升级保留API、Skill隔离空间与待发送任务', () async {
      await op('watch');
      const volumeKey = 'js-volume:remote_rvc_cover:fixture';
      await agent.store.put(volumeKey, {
        'namespace': 'keep-original-task-scope',
      });
      await agent.importPackage(await remoteCoverPackageBytes());
      final updated = agent.extensions.firstWhere((e) => e.id == extension.id);
      expect(updated.config['apiKey'], keyFixture);
      expect(updated.enabled, true);
      expect(
        agent.store.get(volumeKey)?['namespace'],
        'keep-original-task-scope',
      );
      expect(row()['state'], 'watching');
    });

    test('ZIP升级也保留用户导入前写在清单中的API配置', () async {
      final embedded = extension.copyWith(
        manifest: {
          ...extension.manifest,
          'packageManifest': {
            ...extension.packageManifest,
            'settings': {...extension.config, 'apiKey': keyFixture},
          },
        },
        settings: {},
        enabled: true,
      );
      await agent.saveExtension(embedded);
      expect(
        agent.extensions.firstWhere((e) => e.id == extension.id).settings,
        isEmpty,
      );
      await agent.importPackage(await remoteCoverPackageBytes());
      expect(
        agent.extensions
            .firstWhere((e) => e.id == extension.id)
            .config['apiKey'],
        keyFixture,
      );
    });

    test('真实工具流程登记后结束AI回合，后台仍能取得回执发送', () async {
      await agent.saveConnection(
        AgentConnection(
          id: 'qq',
          name: 'fixture',
          selfId: '10001',
          presetId: 'cover',
          aiEnabled: true,
          cooldownSeconds: 0,
        ),
      );
      await agent.disconnect('qq');
      await agent.connect('qq');
      model.handler = (n, request) async => n == 1
          ? {
              'choices': [
                {
                  'message': {
                    'tool_calls': [
                      {
                        'id': 'cover-start',
                        'type': 'function',
                        'function': {
                          'name': 'remote_rvc_cover__remote_cover_start',
                          'arguments': jsonEncode({
                            'song': 'song-id',
                            'model': 'voice-id',
                            'mode': 'chorus',
                            'duration_seconds': 0,
                          }),
                        },
                      },
                    ],
                  },
                },
              ],
            }
          : fixture.answer('已登记完成后发送，请保持管理器运行。');
      transport.receive(id: 'real-cover-input', content: '用音色翻唱高潮，完成发我');
      await fixture.eventually(
        () => model.requests.length == 2 && agent.busySessions.isEmpty,
      );
      expect(row()['state'], 'watching');
      final tools = (model.requests.last['messages'] as List)
          .map(object)
          .where((x) => x['role'] == 'tool');
      expect(text(tools.last['content']), contains('"auto_send":true'));
      http.completed = true;
      await tick();
      expect(row()['state'], 'sent');
      expect(transport.voiceAttempts, 1);
      expect(model.requests, hasLength(2));
    });

    test('新客户端发送工具通过宿主取得回执，不被当成无语音回执', () async {
      await agent.saveConnection(
        AgentConnection(
          id: 'qq',
          name: 'fixture',
          selfId: '10001',
          presetId: 'cover',
          aiEnabled: true,
          cooldownSeconds: 0,
        ),
      );
      await agent.disconnect('qq');
      await agent.connect('qq');
      http.completed = true;
      model.handler = (n, request) async => n == 1
          ? {
              'choices': [
                {
                  'message': {
                    'tool_calls': [
                      {
                        'id': 'cover-send',
                        'type': 'function',
                        'function': {
                          'name': 'remote_rvc_cover__remote_cover_send',
                          'arguments': jsonEncode({'job_id': jobId}),
                        },
                      },
                    ],
                  },
                },
              ],
            }
          : fixture.answer('已发出。');
      transport.receive(id: 'real-manual-send', content: '把做好的翻唱发出来');
      await fixture.eventually(
        () => model.requests.length == 2 && agent.busySessions.isEmpty,
      );
      final tools = (model.requests.last['messages'] as List)
          .map(object)
          .where((x) => x['role'] == 'tool');
      expect(text(tools.last['content']), contains('完整翻唱已发送'));
      expect(row()['state'], 'sent');
      await tick();
      expect(transport.voiceAttempts, 1);
    });
  }, skip: native ? false : '需要本机QuickJS DLL');
}
