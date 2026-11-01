import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/agent/ai.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/images.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/script.dart';
import 'package:qq_bot_manager/agent/store.dart';

import 'agent_ai_features_test.dart' as features;
import 'agent_core_test.dart' as core;

class _BudgetHttp extends AgentHttp {
  final limits = <int>[];
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
    limits.add(timeoutSeconds);
    if (limits.length == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      throw const AgentHttpException('fixture HTTP 502', statusCode: 502);
    }
    return core.answer('恢复成功');
  }
}

void main() {
  test('旧模型配置自动取消固定超时，长任务仅由当前状态和手动取消控制', () {
    final provider = AgentProvider.fromJson({
      'id': 'm',
      'name': '模型',
      'model': 'fixture',
      'baseUrl': 'https://model.example/v1',
      'timeoutSeconds': 60,
    });
    provider.validate();
    expect(provider.timeoutSeconds, 0);
    expect(provider.toJson()['timeoutSeconds'], 0);
    var current = true;
    final turn = AgentTurn(
      () => current,
      startedAt: DateTime.now().subtract(const Duration(hours: 1)),
    );
    expect(turn.active, true);
    turn.check();
    current = false;
    expect(turn.active, false);
    final second = AgentTurn(() => true)..stop();
    expect(() => second.check(), throwsA(isA<AgentException>()));
  });
  group('模型请求恢复', () {
    late HttpServer server;
    late AgentHttp http;
    late AgentProvider provider;
    late CompatibleAgentModel model;
    late Future<void> Function(HttpRequest, int) respond;
    final requests = <Json>[];
    final authorizations = <String?>[];
    final request = <String, dynamic>{
      'model': 'fixture',
      'messages': [
        {'role': 'user', 'content': '测试本地服务'},
      ],
      'stream': false,
    };

    setUp(() async {
      requests.clear();
      authorizations.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http = AgentHttp();
      model = CompatibleAgentModel(http, retryDelay: Duration.zero);
      provider = AgentProvider(
        id: 'test',
        name: '模拟接口',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'fixture',
        apiKey: 'fixture-private-key',
        timeoutSeconds: 5,
      );
      server.listen((r) async {
        try {
          authorizations.add(r.headers.value('authorization'));
          requests.add(object(jsonDecode(await utf8.decoder.bind(r).join())));
          await respond(r, requests.length);
          await r.response.close();
        } catch (_) {
          // A timeout/cancellation may have already closed the local client.
          r.response.close().ignore();
        }
      });
    });
    tearDown(() async {
      http.close();
      await server.close(force: true);
    });

    for (final status in [500, 502, 503, 504]) {
      test('HTTP $status 仅补试一次，同一请求恢复后正常返回', () async {
        respond = (r, count) async {
          r.response.headers.contentType = ContentType.json;
          r.response.statusCode = count == 1 ? status : 200;
          r.response.write(
            count == 1
                ? '{"message":"fixture-private-key do not log"}'
                : jsonEncode(core.answer('已恢复')),
          );
        };
        final progress = <String>[];
        final result = await model.complete(
          provider,
          request,
          CancelToken(),
          onRetry: progress.add,
        );
        expect(jsonEncode(result), contains('已恢复'));
        expect(requests, [request, request]);
        expect(authorizations, [
          'Bearer fixture-private-key',
          'Bearer fixture-private-key',
        ]);
        expect(progress.single, contains('HTTP $status'));
        expect(progress.single, isNot(contains('fixture-private-key')));
      });
    }

    test('连续502不无限重试，保留追踪ID而不显示远端正文或密钥', () async {
      respond = (r, count) async {
        r.response.statusCode = 502;
        r.response.headers.set('x-request-id', 'fixture-$count');
        r.response.write('upstream says fixture-private-key');
      };
      try {
        await model.complete(provider, request, CancelToken());
        fail('must fail');
      } on AgentHttpException catch (e) {
        expect(e.statusCode, 502);
        expect(e.traceId, 'fixture-2');
        expect(e.message, contains('已自动重试 1 次'));
        expect(e.message, contains('模型服务或中转网关异常'));
        expect(e.message, isNot(contains('fixture-private-key')));
        expect(e.message, isNot(contains('upstream says')));
      }
      expect(requests.length, 2);
    });

    test('工具完成后的模型请求重试，不重新执行已完成工具', () async {
      respond = (r, count) async {
        r.response.headers.contentType = ContentType.json;
        if (count == 1) {
          r.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'fixture-call',
                        'type': 'function',
                        'function': {'name': 'fixture_tool', 'arguments': '{}'},
                      },
                    ],
                  },
                },
              ],
            }),
          );
        } else if (count == 2) {
          r.response.statusCode = 502;
        } else {
          r.response.write(jsonEncode(core.answer('工具已完成')));
        }
      };
      final scripts = AgentScripts();
      addTearDown(scripts.close);
      final ai = AgentAi(model, AgentExtensions(http, scripts));
      final session = AgentSession(
        connectionId: 'a',
        selfId: '10001',
        kind: 'group',
        peerId: '20002',
        name: '群',
      );
      var effects = 0;
      final stages = <String>[];
      final answer = await ai.reply(
        provider: provider,
        preset: AgentPreset(id: 'p', name: '预设', prompt: '完成工具后回答'),
        session: session,
        history: [
          AgentMessage(
            id: 'trigger',
            sessionKey: session.key,
            senderId: '30003',
            senderName: '群友',
            segments: [textSegment('执行测试工具')],
          ),
        ],
        skills: [],
        builtinTools: [
          {
            'name': 'fixture_tool',
            'description': '本地测试',
            'parameters': {
              'type': 'object',
              'properties': <String, dynamic>{},
              'additionalProperties': false,
            },
          },
        ],
        onBuiltinTool: (_, _) async {
          effects++;
          return {'text': '工具执行成功'};
        },
        turn: AgentTurn(() => true),
        onUsage: (_, _) {},
        onTool: (_) {},
        onProgress: (phase, _) => stages.add(phase),
      );
      expect(answer, '工具已完成');
      expect(effects, 1);
      expect(requests.length, 3);
      expect(requests[1], requests[2]);
      expect(stages.where((s) => s == 'model-retry').length, 1);
    });

    for (final status in [302, 400, 401, 403, 404, 422, 429]) {
      test('HTTP $status 不自动重发或跟随跳转', () async {
        respond = (r, _) async {
          r.response.statusCode = status;
          r.response.headers.set('location', '/do-not-follow');
          r.response.write('{"message":"fixture-private-key"}');
        };
        await expectLater(
          model.complete(provider, request, CancelToken()),
          throwsA(
            isA<AgentHttpException>()
                .having((e) => e.statusCode, 'statusCode', status)
                .having(
                  (e) => e.message,
                  'sanitized',
                  isNot(contains('fixture-private-key')),
                ),
          ),
        );
        expect(requests.length, 1);
      });
    }

    test('旧模型超时配置不再中断慢响应', () async {
      respond = (r, _) async {
        r.response.headers.contentType = ContentType.json;
        final json = jsonEncode(core.answer('慢响应已完成'));
        r.response.write(json.substring(0, 10));
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 1400));
        r.response.write(json.substring(10));
      };
      final short = AgentProvider.fromJson({
        ...provider.toJson(),
        'timeoutSeconds': 1,
      });
      expect(short.timeoutSeconds, 0);
      expect(
        jsonEncode(await model.complete(short, request, CancelToken())),
        contains('慢响应已完成'),
      );
      expect(requests.length, 1);
    });

    test('取消无限等待的模型请求立即结束，不继续重试', () async {
      final started = Completer<void>();
      respond = (r, _) async {
        r.response.write('{');
        await r.response.flush();
        started.complete();
      };
      // Keep the response open until the caller cancels it.
      final gate = Completer<void>();
      final original = respond;
      respond = (r, n) async {
        await original(r, n);
        await gate.future;
      };
      final cancel = CancelToken();
      final pending = model.complete(provider, request, cancel);
      final checked = expectLater(
        pending,
        throwsA(
          isA<AgentException>().having((e) => e.message, 'cancelled', '任务已停止。'),
        ),
      );
      await started.future;
      cancel.cancel();
      await checked.timeout(const Duration(seconds: 2));
      gate.complete();
      expect(requests.length, 1);
    });

    test('普通非AI接口仍遵守显式超时', () async {
      respond = (r, _) async {
        r.response.write('{');
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 1400));
      };
      await expectLater(
        http.request(
          provider.endpoint('check'),
          method: 'POST',
          body: request,
          timeoutSeconds: 1,
        ),
        throwsA(
          isA<AgentNetworkException>().having(
            (e) => e.failure,
            'failure',
            AgentNetworkFailure.timeout,
          ),
        ),
      );
    });

    test('补试等待期间手动停止，不发第二个请求', () async {
      respond = (r, _) async {
        r.response.statusCode = 502;
      };
      final cancel = CancelToken();
      final delayed = CompatibleAgentModel(
        http,
        retryDelay: const Duration(seconds: 1),
      );
      await expectLater(
        delayed.complete(
          provider,
          request,
          cancel,
          onRetry: (_) => cancel.cancel(),
        ),
        throwsA(
          isA<AgentException>().having((e) => e.message, 'cancel', '任务已停止。'),
        ),
      );
      expect(requests.length, 1);
    });

    test('200但正文格式不符不重发，提示检查接口与流式设置', () async {
      respond = (r, _) async =>
          r.response.write('<html>fixture-private-key</html>');
      await expectLater(
        model.complete(provider, request, CancelToken()),
        throwsA(
          isA<AgentException>().having(
            (e) => e.message,
            'help',
            contains('流式返回设置'),
          ),
        ),
      );
      expect(requests.length, 1);
    });

    test('模型请求与补试均不设置固定超时', () async {
      final budget = _BudgetHttp();
      addTearDown(budget.close);
      await CompatibleAgentModel(
        budget,
        retryDelay: Duration.zero,
      ).complete(provider, request, CancelToken());
      expect(budget.limits, [0, 0]);
    });
  });

  group('会话图片缓存', () {
    late features.FeatureHttp http;
    late AgentImages images;
    late DateTime now;
    Json picture(String ref) => {
      'type': 'image',
      'data': {'url': ref},
    };
    const source = 'https://images.example/test.png?rkey=fixture';
    setUp(() {
      now = DateTime(2026, 10, 28, 18);
      http = features.FeatureHttp()
        ..handler = (_) async => features.page('bad link', status: 400);
      images = AgentImages(http, now: () => now);
    });
    tearDown(() => http.close());
    Future<void> failed(
      String scope, [
      String url = source,
      bool cached = false,
    ]) async {
      await expectLater(
        images.prepare(picture(url), 512, CancelToken(), scope: scope),
        throwsA(
          isA<AgentImageException>().having((e) => e.cached, 'cached', cached),
        ),
      );
    }

    test('旧400图片暂停重复下载5分钟，新URL和其他会话独立', () async {
      await failed('a');
      await failed('a', source, true);
      expect(http.requests.length, 1);
      await failed('b');
      await failed('a', '$source-new');
      expect(http.requests.length, 3);
      now = now.add(const Duration(minutes: 4, seconds: 59));
      await failed('a', source, true);
      now = now.add(const Duration(seconds: 1));
      await failed('a');
      expect(http.requests.length, 4);
      images.clear(scope: 'a');
      await failed('a');
      expect(http.requests.length, 5);
    });

    test('503等临时失败仅退避30秒', () async {
      http.handler = (_) async => features.page('temporary', status: 503);
      await failed('a');
      now = now.add(const Duration(seconds: 29));
      await failed('a', source, true);
      now = now.add(const Duration(seconds: 1));
      await failed('a');
      expect(http.requests.length, 2);
    });

    test('成功图片重复使用已处理数据，尺寸、会话与10分钟期限受限', () async {
      final png = img.encodePng(img.Image(width: 800, height: 400));
      http.handler = (_) async =>
          (bytes: png, status: 200, headers: <String, String>{});
      final first = await images.prepare(
        picture(source),
        512,
        CancelToken(),
        scope: 'a',
      );
      final second = await images.prepare(
        picture(source),
        512,
        CancelToken(),
        scope: 'a',
      );
      expect(identical(first, second), true);
      expect(first.width, 512);
      expect(http.requests.length, 1);
      await images.prepare(picture(source), 256, CancelToken(), scope: 'a');
      await images.prepare(picture(source), 512, CancelToken(), scope: 'b');
      expect(http.requests.length, 3);
      now = now.add(const Duration(minutes: 10));
      await images.prepare(picture(source), 512, CancelToken(), scope: 'a');
      expect(http.requests.length, 4);
      final cancelled = CancelToken()..cancel();
      await expectLater(
        images.prepare(picture(source), 512, cancelled, scope: 'a'),
        throwsA(isA<AgentException>()),
      );
    });

    test('取消的读取不写入失败缓存', () async {
      final cancel = CancelToken();
      http.handler = (_) async {
        cancel.cancel();
        throw const AgentException('任务已停止。');
      };
      await expectLater(
        images.prepare(picture(source), 512, cancel, scope: 'a'),
        throwsA(isA<AgentException>()),
      );
      http.handler = (_) async => features.page('bad link', status: 400);
      await failed('a');
      expect(http.requests.length, 2);
    });

    test('失败缓存最多64项，淘汰最久未使用记录', () async {
      for (var i = 0; i < 64; i++) {
        await failed('a', '$source-$i');
      }
      await failed('a', '$source-0', true);
      await failed('a', '$source-64');
      await failed('a', '$source-0', true);
      await failed('a', '$source-1');
      expect(http.requests.length, 66);
    });

    test('连续两轮旧图失败仅警告一次，仍给模型提供文字与未读取标记', () async {
      final scripts = AgentScripts();
      addTearDown(scripts.close);
      final model = core.FakeAgentModel();
      final ai = AgentAi(model, AgentExtensions(http, scripts), now: () => now);
      final session = AgentSession(
        connectionId: 'a',
        selfId: '10001',
        kind: 'group',
        peerId: '20002',
        name: '群',
      );
      final message = AgentMessage(
        id: 'trigger',
        sessionKey: session.key,
        senderId: '30003',
        senderName: '群友',
        segments: [textSegment('这是什么'), picture(source)],
      );
      final notices = <String>[];
      for (var i = 0; i < 2; i++) {
        expect(
          await ai.reply(
            provider: AgentProvider(
              id: 'v',
              name: '视觉',
              baseUrl: 'https://model.example/v1',
              model: 'fixture',
              vision: true,
            ),
            preset: AgentPreset(id: 'p', name: '预设', prompt: '回答'),
            session: session,
            history: [message],
            triggerMessage: message,
            skills: [],
            turn: AgentTurn(() => true),
            onUsage: (_, _) {},
            onTool: (_) {},
            onNotice: notices.add,
          ),
          '测试回复',
        );
      }
      expect(http.requests.length, 1);
      expect(notices.length, 1);
      expect(jsonEncode(model.requests.last), contains('不可猜测图片内容'));
      expect(jsonEncode(model.requests.last), contains('暂缓重复下载'));
    });
  });

  test('本地500条记录只选预设条数，模型日志记录实际输入而非本地总数', () async {
    final store = AgentStore.memory();
    final model = core.FakeAgentModel();
    late core.FakeAgentTransport transport;
    final agent = AgentController(
      store: store,
      model: model,
      transportFactory: (c) => transport = core.FakeAgentTransport(c),
    );
    addTearDown(() async {
      await agent.shutdown();
      agent.dispose();
    });
    await agent.initialize();
    await agent.saveProvider(
      AgentProvider(
        id: 'm',
        name: '模拟服务',
        baseUrl: 'https://model.example/v1',
        model: 'fixture',
      ),
    );
    await agent.savePreset(
      AgentPreset(
        id: 'p',
        name: '预设',
        prompt: '回答',
        providerId: 'm',
        historyMessages: 2,
      ),
    );
    await agent.saveConnection(
      AgentConnection(
        id: 'c',
        name: '连接',
        selfId: '10001',
        aiEnabled: true,
        cooldownSeconds: 0,
        presetId: 'p',
      ),
    );
    final session = AgentSession(
      connectionId: 'c',
      selfId: '10001',
      kind: 'group',
      peerId: '20002',
      name: '群',
    );
    await store.put('session:${session.key}', session.toJson());
    for (var i = 0; i < 499; i++) {
      await store.append(
        AgentMessage(
          id: 'history-$i',
          sessionKey: session.key,
          senderId: '30003',
          senderName: '群友',
          segments: [textSegment('第$i条历史')],
        ),
      );
    }
    await agent.connect('c');
    transport.receive(id: 'new', content: '本次新问题');
    await core.eventually(
      () => transport.sent.isNotEmpty && agent.busySessions.isEmpty,
    );
    final request = model.requests.single;
    expect(
      (request['messages'] as List)
          .map(object)
          .where((m) => m['role'] == 'user')
          .length,
      3,
    );
    expect(jsonEncode(request), isNot(contains('第0条历史')));
    expect(
      agent.logs.where((l) => l['stage'] == 'preparing').single['message'],
      contains('本地候选 500 条'),
    );
    expect(
      agent.logs.where((l) => l['stage'] == 'context-ready').single['message'],
      contains('已选用 3 条聊天消息'),
    );
    final event = agent.logs.where((l) => l['stage'] == 'model').single;
    expect(
      text(event['message']),
      contains('${(request['messages'] as List).length} 条输入'),
    );
    expect(text(event['message']), contains('持续等待，可手动停止'));
    expect(text(event['message']), isNot(contains('第498条历史')));
  });
}
