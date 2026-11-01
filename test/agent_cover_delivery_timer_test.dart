import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'agent_core_test.dart' as fixture;
import 'agent_cover_delivery_test.dart'
    show DeliveryHttp, DeliveryTransport, jobId, keyFixture;
import 'support/remote_cover_package_fixture.dart' show remoteCoverPackageBytes;

void main() {
  test(
    '持久存储的真实后台定时器无需人工调用处理方法也会发送',
    () async {
      final parent = Directory('build').absolute;
      final temp = await parent.createTemp('qqm-cover-timer-');
      AgentController? agent;
      try {
        Hive.init(temp.path);
        final store = AgentStore();
        final http = DeliveryHttp()..completed = true;
        final model = fixture.FakeAgentModel();
        late DeliveryTransport transport;
        agent = AgentController(
          store: store,
          http: http,
          model: model,
          externalSourcesRoot: Directory('${temp.path}/sources'),
          transportFactory: (c) => transport = DeliveryTransport(c),
        );
        await agent.initialize();
        await agent.importPackage(await remoteCoverPackageBytes());
        var e = agent.extensions.firstWhere((e) => e.id == 'remote_rvc_cover');
        await agent.saveExtension(
          e.copyWith(enabled: true, settings: {'apiKey': keyFixture}),
        );
        e = agent.extensions.firstWhere((e) => e.id == 'remote_rvc_cover');
        await agent.savePreset(
          AgentPreset(
            id: 'timer',
            name: 'fixture',
            prompt: 'fixture',
            skillIds: [e.id],
          ),
        );
        await agent.saveConnection(
          AgentConnection(
            id: 'qq',
            name: 'fixture',
            selfId: '10001',
            aiEnabled: false,
            presetId: 'timer',
          ),
        );
        await agent.connect('qq');
        final c = agent.connection('qq')!,
            s = await agent.openSession('qq', 'group', '20002');
        final m = AgentMessage(
          id: 'ob:timer-ask',
          sessionKey: s.key,
          senderId: '30003',
          senderName: '用户',
          segments: [textSegment('完成后发给我')],
        );
        await store.append(m);
        await agent.coverDeliveryOperation(c, e, s, m, {
          'action': 'watch',
          'jobId': jobId,
          'scope':
              'qqm-zip:11111111-1111-4111-8111-111111111111|onebot:10001|group:20002',
        });
        final row = store.all('agent-cover-delivery').single;
        await store.put(text(row['key']), {
          ...row,
          'nextCheck': DateTime.now()
              .subtract(const Duration(seconds: 1))
              .toIso8601String(),
        });
        final deadline = DateTime.now().add(const Duration(seconds: 18));
        while (DateTime.now().isBefore(deadline) &&
            store.all('agent-cover-delivery').single['state'] != 'sent') {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(store.all('agent-cover-delivery').single['state'], 'sent');
        expect(transport.voiceAttempts, 1);
        expect(model.requests, isEmpty);
        expect(
          jsonEncode(store.all('agent-cover-delivery')),
          isNot(contains(keyFixture)),
        );
      } finally {
        await agent?.shutdown();
        agent?.dispose();
        await Hive.close();
        if (temp.parent.absolute.path != parent.path ||
            !temp.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('qqm-cover-timer-')) {
          throw StateError('Unexpected test directory; refusing cleanup');
        }
        await temp.delete(recursive: true);
      }
    },
    skip: Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
        ? '需要本机QuickJS DLL'
        : false,
  );
}
