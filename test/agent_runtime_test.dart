import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'agent_js_packages_test.dart' as fixture;

void main() {
  group(
    '常驻插件运行时',
    () {
      late AgentStore store;
      late AgentHttp http;
      late AgentJsPackages runner;
      setUp(() async {
        store = AgentStore.memory();
        await store.open();
        http = AgentHttp();
        runner = AgentJsPackages(store, http);
      });
      tearDown(() async {
        await runner.drain();
        http.close();
        await store.close();
      });
      test('生命周期钩子与provider共享原模块状态，按机器人账号隔离', () async {
        final e = AgentExtension.fromPackage(
          fixture.bundle(
            source: r'''
        let calls=0;export function setup(){};
        export const hooks={'before-llm-messages':ctx=>{calls++;ctx.messages.push({role:'user',content:'hook-'+calls});},'after-response':()=>{calls++;}};
        export const providers={'counter':()=>({calls})};
      ''',
          ),
        );
        Future<Json> run(
          String scope,
          String operation, {
          String name = '',
          Json input = const {},
        }) => runner.run(
          manifest: e.manifest,
          settings: e.config,
          operation: operation,
          scope: scope,
          args: {'name': name},
          input: input,
          active: () => true,
        );
        final first = await run(
          'onebot:a',
          'hook',
          name: 'before-llm-messages',
          input: {'messages': <Json>[]},
        );
        expect(
          text(object((first['messages'] as List).single)['content']),
          'hook-1',
        );
        await run('onebot:a', 'hook', name: 'after-response');
        expect(
          object(
            (await run('onebot:a', 'provider', name: 'counter'))['value'],
          )['calls'],
          2,
        );
        expect(
          object(
            (await run('onebot:b', 'provider', name: 'counter'))['value'],
          )['calls'],
          0,
        );
        await runner.stopScope('onebot:a');
        expect(
          object(
            (await run('onebot:a', 'provider', name: 'counter'))['value'],
          )['calls'],
          0,
        );
      });
    },
    skip: Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
        ? '需要测试JavaScript引擎'
        : false,
  );
}
