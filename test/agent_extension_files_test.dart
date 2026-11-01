import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/extension_files.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/package_bundle.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/ui/extension_file_manager.dart';
import 'agent_js_packages_test.dart' show bundle;

Uint8List source(String value) => Uint8List.fromList(utf8.encode(value));
const entry =
    "import {answer} from './lib/value.js'; export function setup(api){api.registerTool({id:'run',description:'fixture',parameters:{type:'object',properties:{}},execute(){return {content:answer}}});}";
AgentExtension fixture() => AgentExtension.fromPackage(
  bundle(
    source: entry,
    files: {
      'lib/value.js': "export const answer='原始逻辑';",
      'docs/readme.md': '使用说明',
    },
    extra: {
      'configSchema': {
        'API_KEY': {'type': 'string', 'secret': true},
      },
    },
  ),
);

void main() {
  test('JSON/HTTP/Hetu插件与Skill可以编辑完整清单，保留独立设置和密钥', () {
    for (final kind in ['plugin', 'skill']) {
      final extension =
          AgentExtension.parse(
            jsonEncode({
              'schema': 1,
              'id': 'my_$kind',
              'name': '示例',
              'kind': kind,
              if (kind == 'skill') 'prompt': '旧提示词',
              if (kind == 'plugin')
                'commands': [
                  {
                    'prefix': '/hello',
                    'handler': {'type': 'template', 'text': 'hello'},
                  },
                ],
            }),
          ).copyWith(
            enabled: true,
            secrets: {'TOKEN': 'fixture-private'},
            settings: {'custom': true},
          );
      final workspace = AgentExtensionFiles.read(extension);
      final data = object(jsonDecode(workspace.readText('$kind.json')))
        ..['name'] = '改名'
        ..[kind == 'skill' ? 'prompt' : 'description'] = '新内容';
      final result = workspace.updated(extension, {
        '$kind.json': source(jsonEncode(data)),
      });
      expect(result.name, '改名');
      expect(result.secrets, extension.secrets);
      expect(result.settings, extension.settings);
      expect(result.enabled, true);
      expect(
        () => workspace.updated(extension, {
          '$kind.json': source(jsonEncode({...data, 'id': 'other'})),
        }),
        throwsA(isA<AgentException>()),
      );
    }
  });
  test('完整包保留原始字节、清单可编辑、多文件重命名一起提交、拒绝路径与大小冲突', () {
    final extension = fixture(),
        workspace = AgentExtensionFiles.read(extension);
    final changed = Map<String, Uint8List>.of(workspace.files)
      ..remove('lib/value.js');
    changed['src/value.js'] = source("export const answer='新逻辑';");
    changed['index.js'] = source(
      entry.replaceAll('./lib/value.js', './src/value.js'),
    );
    final manifest = object(jsonDecode(workspace.readText('skill.json')))
      ..['name'] = '新名称';
    changed['skill.json'] = source(jsonEncode(manifest));
    final next = workspace.updated(extension, changed),
        result = AgentExtensionFiles.read(next);
    expect(next.name, '新名称');
    expect(result.files.keys, contains('src/value.js'));
    expect(result.files.keys, isNot(contains('lib/value.js')));
    expect(result.readText('index.js'), contains('./src/value.js'));
    expect(result.revision, isNot(workspace.revision));
    expect(
      AgentExtension.fromPackage(
        AgentPackageBundle.encode(next.manifest, next.config),
      ).name,
      '新名称',
    );
    for (final path in [
      '../x.js',
      '/x.js',
      r'C:\x.js',
      'x\\y.js',
      'node_modules/x.js',
      'NoDe_Modules/a.js',
      'NUL',
      'file.dll',
      'a/../b.js',
    ]) {
      expect(
        () => workspace.updated(extension, {...changed, path: source('bad')}),
        throwsA(isA<AgentException>()),
        reason: path,
      );
    }
    expect(
      () => workspace.updated(extension, {
        ...changed,
        'INDEX.js': source('duplicate'),
      }),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => workspace.updated(extension, {...changed, 'src': source('file')}),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => workspace.updated(extension, {
        ...changed,
        'huge.bin': Uint8List(8 * 1024 * 1024 + 1),
      }),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => workspace.updated(extension, {...changed}..remove('skill.json')),
      throwsA(isA<AgentException>()),
    );
  });

  test(
    '真实引擎校验后热加载新工具逻辑；语法失败不覆盖；旧编辑器不能覆盖新版本',
    () async {
      final agent = AgentController(store: AgentStore.memory());
      try {
        await agent.initialize();
        await agent.saveExtension(
          fixture().copyWith(
            settings: {'API_KEY': 'fixture-private'},
            enabled: true,
          ),
        );
        final workspace = agent.extensionFiles('fixture');
        final latest = agent.extensions.firstWhere((e) => e.id == 'fixture');
        await agent.saveExtension(
          latest.copyWith(settings: {'API_KEY': 'fixture-new-private'}),
        );
        final changed = {
          ...workspace.files,
          'lib/value.js': source("export const answer='编辑生效';"),
        };
        await agent.saveExtensionFiles(
          'fixture',
          changed,
          expectedRevision: workspace.revision,
        );
        final next = agent.extensions.firstWhere((e) => e.id == 'fixture');
        expect(next.config['API_KEY'], 'fixture-new-private');
        expect(next.enabled, true);
        final executed = await agent.packages.run(
          manifest: next.manifest,
          settings: next.config,
          operation: 'tool',
          args: {'id': 'run', 'args': <String, dynamic>{}},
          active: () => true,
        );
        expect(executed['content'], '编辑生效');
        await expectLater(
          agent.saveExtensionFiles(
            'fixture',
            workspace.files,
            expectedRevision: workspace.revision,
          ),
          throwsA(isA<AgentException>()),
        );
        final good = agent.extensionFiles('fixture');
        await expectLater(
          agent.saveExtensionFiles('fixture', {
            ...good.files,
            'index.js': source('export function {'),
          }, expectedRevision: good.revision),
          throwsA(isA<AgentException>()),
        );
        expect(agent.extensionFiles('fixture').revision, good.revision);
        final simultaneous = await Future.wait([
          agent
              .saveExtensionFiles('fixture', {
                ...good.files,
                'lib/value.js': source("export const answer='a';"),
              }, expectedRevision: good.revision)
              .then((_) => 'ok', onError: (_) => 'conflict'),
          agent
              .saveExtensionFiles('fixture', {
                ...good.files,
                'lib/value.js': source("export const answer='b';"),
              }, expectedRevision: good.revision)
              .then((_) => 'ok', onError: (_) => 'conflict'),
        ]);
        expect(simultaneous, ['ok', 'conflict']);
      } finally {
        await agent.shutdown();
        agent.dispose();
      }
    },
    skip: Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
        ? '需要测试引擎'
        : false,
  );

  for (final width in [360.0, 1280.0]) {
    testWidgets('文件管理$width可浏览Skill源码并保护未保存修改，无布局溢出', (tester) async {
      final agent = AgentController(store: AgentStore.memory());
      await agent.store.open();
      await agent.store.put('extension:fixture', fixture().toJson());
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 850);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => AgentExtensionFileManager(
                      controller: agent,
                      extensionId: 'fixture',
                    ),
                  ),
                ),
                child: const Text('打开文件管理'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开文件管理'));
      await tester.pumpAndSettle();
      if (width < 760) {
        await tester.tap(find.byTooltip('浏览文件'));
        await tester.pumpAndSettle();
      }
      expect(find.text('skill.json'), findsOneWidget);
      await tester.tap(find.text('skill.json'));
      await tester.pumpAndSettle();
      expect(find.textContaining('清单可编辑'), findsOneWidget);
      final edit = find.byKey(const Key('agent-source-editor'));
      final controller = tester.widget<TextField>(edit).controller!;
      expect(controller.text, contains('apiVersion'));
      await tester.enterText(edit, controller.text.replaceAll('测试原包', '草稿未保存'));
      await tester.pump();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(edit).controller!.text,
        contains('草稿未保存'),
      );
      expect(
        agent.extensionFiles('fixture').readText('skill.json'),
        isNot(contains('草稿未保存')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await agent.shutdown();
      agent.dispose();
    });
  }
}
