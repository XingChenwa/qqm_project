import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/package_compatibility.dart';
import 'package:qq_bot_manager/agent/store.dart';

import 'agent_js_packages_test.dart' show bundle;

void main() {
  test('自检缺少依赖时保留原因，配置恢复后不再误标为缺少运行环境', () {
    final manifest = {'id': 'dependency-check', 'files': <String, dynamic>{}};
    final unavailable = packageCompatibility(manifest, {
      'available': {'ok': false, 'reason': '缺少 Python、流水线脚本'},
    });
    expect(unavailable['state'], 'blocked');
    expect(unavailable['blockers'], contains('扩展自检未通过：缺少 Python、流水线脚本'));
    expect(
      AgentExtension({
        ...manifest,
        'compatibility': unavailable,
      }).compatibilityLabel,
      '缺少运行环境或配置',
    );
    final restored = packageCompatibility(manifest, {
      'available': {'ok': true},
    });
    expect(restored['state'], 'ready');
    expect(restored['blockers'], isEmpty);
  });

  final native = Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] != null;
  group('桌面专用包的导入和依赖诊断', () {
    late AgentController agent;
    setUp(() async {
      agent = AgentController(store: AgentStore.memory(), http: AgentHttp());
      await agent.initialize();
    });
    tearDown(() async {
      await agent.shutdown();
      agent.dispose();
    });

    test('child_process具名导入成功，实际外部进程调用明确失败', () async {
      final extension = AgentExtension.fromPackage(
        bundle(
          source: r'''
        import {spawn,spawnSync,exec,execSync,execFile,execFileSync,fork} from 'node:child_process';
        export function setup(api){
          api.registerTool({id:'probe',name:'依赖检查',description:'验证不执行外部命令',
            parameters:{type:'object',properties:{}},execute(){
              try{execFileSync('not-a-real-program',[]);return {content:'不应执行成功'};}
              catch(error){return {content:String(error.message),isError:true};}
            }});
        }
      ''',
        ),
      );
      final runner = AgentJsPackages(agent.store, agent.http);
      try {
        final found = await runner.run(
          manifest: extension.manifest,
          settings: {},
          operation: 'inspect',
          active: () => true,
        );
        expect(found['tools'], hasLength(1));
        final result = await runner.run(
          manifest: extension.manifest,
          settings: {},
          operation: 'tool',
          args: {'id': 'probe'},
          active: () => true,
        );
        expect(result['isError'], true);
        expect(result['content'], contains('child_process.execFileSync'));
        expect(result['content'], contains('尚未由当前跨平台宿主开放'));
      } finally {
        await runner.drain();
      }
    });

    test('自检信息脱敏保存且可见，修正设置后可以启用', () async {
      final extension = AgentExtension.fromPackage(
        bundle(
          source: r'''
          let cfg;
          export function setup(api){cfg=api.config;}
          export function available(){return cfg().ready ? true : {ok:false,reason:'资源未配置 '+cfg().apiKey};}
        ''',
          extra: {
            'settings': {'ready': false, 'apiKey': 'fixture-secret-dependency'},
            'configSchema': {
              'ready': {'type': 'boolean'},
              'apiKey': {'type': 'string', 'secret': true},
            },
          },
        ),
      );
      await agent.saveExtension(extension);
      final stored = agent.extensions.singleWhere((e) => e.id == extension.id);
      expect(stored.enabled, false);
      expect(stored.compatibility['state'], 'blocked');
      expect(
        jsonEncode(stored.compatibility),
        isNot(contains('fixture-secret-dependency')),
      );
      expect(stored.compatibilityDetails.join(), contains('[已隐藏]'));
      await agent.saveExtension(
        stored.copyWith(enabled: true, settings: {'ready': true}),
      );
      final configured = agent.extensions.singleWhere(
        (e) => e.id == extension.id,
      );
      expect(configured.enabled, true);
      expect(configured.compatibility['state'], 'ready');
    });

    test('升级复检将缺少依赖的旧启用包安全关闭并保留配置和源码', () async {
      final store = AgentStore.memory();
      await store.open();
      final extension = AgentExtension.fromPackage(
        bundle(
          source: r'''
          export function setup(api){}
          export function available(){return {ok:false,reason:'需要配套流水线'};}
        ''',
          extra: {
            'settings': {'voice': 'my-voice'},
          },
        ),
      );
      await store.put('meta:initialized', {'schema': 1});
      await store.put(
        'extension:${extension.id}',
        extension
            .copyWith(
              enabled: true,
              manifest: {
                ...extension.manifest,
                'compatibility': {'hostVersion': 2, 'state': 'ready'},
              },
            )
            .toJson(),
      );
      final restored = AgentController(store: store);
      try {
        await restored.initialize();
        final checked = restored.extensions.single;
        expect(checked.enabled, false);
        expect(checked.compatibility['hostVersion'], agentPackageHostVersion);
        expect(checked.compatibilityDetails.join(), contains('需要配套流水线'));
        expect(checked.config['voice'], 'my-voice');
        expect(checked.manifest['files'], extension.manifest['files']);
      } finally {
        await restored.shutdown();
        restored.dispose();
      }
    });
    final directory = Platform.environment['QQM_AGENT_EXTRA_PACKAGE_DIR'];
    final original = directory == null
        ? null
        : File('$directory/skills-sing-cover.zip');
    test(
      '原始sing-cover双层ZIP导入并注册三工具，明确说明环境缺失而不假报可用',
      () async {
        final bytes = await original!.readAsBytes();
        await agent.importPackage(bytes);
        final extension = agent.extensions.singleWhere(
          (e) => e.id == 'sing-cover',
        );
        expect(extension.enabled, false);
        expect(extension.tools.map((t) => t['name']).toSet(), {
          'sing-cover__sing_cover',
          'sing-cover__answer_dialog',
          'sing-cover__cancel_cover',
        });
        expect(extension.compatibility['state'], 'blocked');
        expect(extension.compatibilityDetails.join(), contains('Python 环境'));
        expect(extension.compatibilityDetails.join(), contains('流水线脚本'));
        expect(extension.compatibilityDetails.join(), contains('外部系统程序'));
        expect(
          object(extension.manifest['files'])['index.js'],
          object(
            AgentExtension.fromPackage(bytes).manifest['files'],
          )['index.js'],
        );
        await expectLater(
          agent.saveExtension(extension.copyWith(enabled: true)),
          throwsA(
            isA<AgentException>().having(
              (e) => e.message,
              '明确说明依赖缺失',
              contains('Python 环境'),
            ),
          ),
        );
        expect(
          agent.extensions.singleWhere((e) => e.id == extension.id).enabled,
          false,
        );
        expect(await original.readAsBytes(), bytes);
      },
      skip: original == null || !original.existsSync()
          ? '需提供原始skills-sing-cover.zip以验证完整原包'
          : false,
    );
  }, skip: native ? false : '需要测试JavaScript引擎');
}
