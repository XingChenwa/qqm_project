import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'agent_core_test.dart' as core;
import 'agent_js_packages_test.dart' as fixture;

class CountingStore extends AgentStore {
  final reads = <String, int>{};
  int syncs = 0;
  CountingStore() : super.memory();
  @override
  Json? get(String key) {
    reads.update(key, (n) => n + 1, ifAbsent: () => 1);
    return super.get(key);
  }

  @override
  Future<void> flush() async {
    syncs++;
    await super.flush();
  }
}

class DelayedFixtureHttp extends AgentHttp {
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
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return (
      bytes: Uint8List.fromList(utf8.encode('offline-ok')),
      status: 200,
      headers: <String, String>{},
    );
  }
}

void main() {
  test('配置快照按类别更新，不被日志和用量写入失效，也不能原地篡改缓存', () async {
    final tracked = CountingStore();
    final agent = AgentController(store: tracked);
    addTearDown(() async {
      await agent.shutdown();
      agent.dispose();
    });
    await agent.initialize();
    await agent.saveConnection(
      AgentConnection(
        id: 'test',
        name: '测试',
        selfId: '10001',
        pluginIds: ['test-plugin'],
      ),
    );
    await agent.saveExtension(
      AgentExtension({
        'schema': 1,
        'id': 'test-plugin',
        'name': '测试插件',
        'kind': 'plugin',
        'description': '性能测试',
        'commands': [
          {
            'prefix': '/perf',
            'handler': {'type': 'template', 'text': '测试'},
          },
        ],
        'settings': {
          'nested': {'value': 1},
        },
      }),
    );
    final extensions = agent.extensions, connections = agent.connections;
    tracked.reads.clear();
    for (var i = 0; i < 200; i++) {
      expect(identical(agent.extensions, extensions), true);
      expect(identical(agent.connections, connections), true);
    }
    expect(tracked.reads, isEmpty);
    expect(
      () =>
          agent.extensions
                  .firstWhere((e) => e.id == 'test-plugin')
                  .manifest['name'] =
              '篡改',
      throwsUnsupportedError,
    );
    expect(
      () => connections.single.pluginIds.add('other'),
      throwsUnsupportedError,
    );
    await tracked.addUsage(1, 1);
    expect(identical(agent.extensions, extensions), true);
    await agent.saveExtension(
      agent.extensions
          .firstWhere((e) => e.id == 'test-plugin')
          .copyWith(enabled: true),
    );
    expect(identical(agent.extensions, extensions), false);
    expect(
      agent.extensions.firstWhere((e) => e.id == 'test-plugin').enabled,
      true,
    );
  });
  test('历史版本只在消息实际变化时更新，原get仍然返回独立副本', () async {
    final store = AgentStore.memory();
    await store.open();
    await store.put('extension:sample', {
      'settings': {'value': 1},
    });
    final revision = store.version('extension');
    final copy = store.get('extension:sample')!;
    (copy['settings'] as Map)['value'] = 2;
    expect(object(store.get('extension:sample')?['settings'])['value'], 1);
    expect(store.version('extension'), revision);
    final m = AgentMessage(
      id: 'one',
      sessionKey: 'test',
      senderId: '10001',
      senderName: '测试',
      segments: [textSegment('内容')],
    );
    await store.append(m);
    final history = store.keyVersion('history:test');
    expect(await store.append(m), false);
    expect(store.keyVersion('history:test'), history);
    await store.updateMessage(
      'test',
      'one',
      (m) => m.copyWith(autoHandled: true),
    );
    expect(store.keyVersion('history:test'), greaterThan(history));
    expect(store.version('extension'), revision);
    await store.close();
  });
  group(
    '连接后空闲负载与按需唤醒',
    () {
      late CountingStore store;
      late AgentController agent;
      late core.FakeAgentTransport transport;
      setUp(() async {
        store = CountingStore();
        agent = AgentController(
          store: store,
          transportFactory: (c) => transport = core.FakeAgentTransport(c),
        );
        await agent.initialize();
      });
      tearDown(() async {
        await agent.shutdown();
        agent.dispose();
      });
      test('启动常驻插件后不周期读取整份源码，钩子不强制磁盘同步', () async {
        final e = AgentExtension.fromPackage(
          fixture.bundle(
            extra: {'id': 'idle', 'name': '空闲测试'},
            files: {'asset.txt': 'x' * 200000},
            source:
                "export function setup(){};export function activate(){setInterval(()=>{},60000);}export const hooks={'before-llm-messages':()=>{}};",
          ),
        );
        await agent.saveExtension(e.copyWith(enabled: true));
        await agent.saveConnection(
          AgentConnection(
            id: 'test',
            name: '测试',
            selfId: '10001',
            pluginIds: [e.id],
          ),
        );
        await agent.connect('test');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        store.reads.clear();
        final syncs = store.syncs;
        var notices = 0;
        agent.addListener(() => notices++);
        for (var i = 0; i < 30; i++) {
          transport.onDiagnostic?.call('info', '离线测试日志');
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          store.reads.keys.where((key) => key.startsWith('extension:')),
          isEmpty,
        );
        expect(notices, lessThan(4));
        expect(store.syncs, syncs);
      });
      test('闲置运行时及时被新任务、网络结果和JS定时器唤醒', () async {
        final http = DelayedFixtureHttp();
        final runner = AgentJsPackages(store, http);
        final e = AgentExtension.fromPackage(
          fixture.bundle(
            extra: {
              'permissions': ['web_fetch'],
            },
            source: r'''
        let ticks=0,api;export function setup(a){api=a;}export function activate(){setTimeout(()=>ticks++,50);}
        export const providers={status:()=>({ticks}),network:async()=>({result:await (await api.fetch('https://fixture.test/')).text()})};
      ''',
          ),
        );
        Future<Json> run(String operation, String name) => runner.run(
          manifest: e.manifest,
          settings: e.config,
          operation: operation,
          scope: 'wake-test',
          args: {'name': name},
          active: () => true,
        );
        try {
          await run('activate', '');
          await Future<void>.delayed(const Duration(milliseconds: 180));
          final elapsed = Stopwatch()..start();
          expect(
            object((await run('provider', 'status'))['value'])['ticks'],
            1,
          );
          expect(
            object((await run('provider', 'network'))['value'])['result'],
            'offline-ok',
          );
          expect(
            elapsed.elapsedMilliseconds,
            lessThan(700),
            reason: '空闲等待不应阻塞已到达的任务和网络结果',
          );
        } finally {
          await runner.drain();
          http.close();
        }
      });
    },
    skip: Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
        ? '需要本机JavaScript引擎'
        : false,
  );
}
