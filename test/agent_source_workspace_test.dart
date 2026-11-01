import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/services/desktop_file_location.dart';
import 'agent_extension_files_test.dart' show fixture;

Future<void> until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('等待源码同步超时');
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void main() {
  late Directory temporary;
  late AgentController agent;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'qqm-external-source-test-',
    );
    agent = AgentController(
      store: AgentStore.memory(),
      externalSourcesRoot: Directory(p.join(temporary.path, 'agent_sources')),
    );
    await agent.initialize();
  });
  tearDown(() async {
    await agent.shutdown();
    agent.dispose();
    expect(p.basename(temporary.path), startsWith('qqm-external-source-test-'));
    await temporary.delete(recursive: true);
  });
  test('JSON Skill目录是真实文件，外部保存无格式限制；无效JSON保留且不替换有效运行包', () async {
    await agent.saveExtension(
      AgentExtension.parse(
        jsonEncode({
          'schema': 1,
          'id': 'disk_skill',
          'name': '磁盘Skill',
          'kind': 'skill',
          'prompt': '原始提示',
        }),
      ).copyWith(enabled: true, secrets: {'TOKEN': 'fixture-secret'}),
    );
    final directory = await agent.extensionSourceDirectory('disk_skill'),
        file = File(p.join(directory.path, 'skill.json'));
    expect(await file.exists(), isTrue);
    final original = await file.readAsString();
    await file.writeAsString('{ incomplete JSON', flush: true);
    await expectLater(
      agent.reloadExtensionSource('disk_skill'),
      throwsA(isA<AgentException>()),
    );
    expect(await file.readAsString(), '{ incomplete JSON');
    expect(
      agent.extensions.firstWhere((e) => e.id == 'disk_skill').prompt,
      '原始提示',
    );
    expect(agent.sourceStatus('disk_skill'), contains('源文件已保留'));
    final changed = Map<String, dynamic>.from(jsonDecode(original) as Map)
      ..['prompt'] = '外部修改已生效';
    await file.writeAsString(jsonEncode(changed), flush: true);
    await until(
      () =>
          agent.extensions.firstWhere((e) => e.id == 'disk_skill').prompt ==
          '外部修改已生效',
    );
    final current = agent.extensions.firstWhere((e) => e.id == 'disk_skill');
    expect(current.enabled, isTrue);
    expect(current.secrets['TOKEN'], 'fixture-secret');
    final revision = agent.store.version('extension');
    await agent.extensionSourceDirectory('disk_skill');
    await agent.extensionSourceDirectory('disk_skill');
    expect(
      agent.store.version('extension'),
      revision,
      reason: 'JSON缩进差异不应导致重复保存或重启运行包',
    );
  });
  test('内外同时编辑保留两份内容；手动重新加载明确采用磁盘版本', () async {
    await agent.saveExtension(
      AgentExtension.parse(
        jsonEncode({
          'schema': 1,
          'id': 'conflict',
          'name': '冲突Skill',
          'kind': 'skill',
          'prompt': 'initial',
        }),
      ),
    );
    final directory = await agent.extensionSourceDirectory('conflict'),
        file = File(p.join(directory.path, 'skill.json'));
    await agent.pauseExternalSources();
    final disk = Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    )..['prompt'] = '磁盘版本';
    await file.writeAsString(jsonEncode(disk), flush: true);
    final current = agent.extensions.firstWhere((e) => e.id == 'conflict');
    await agent.saveExtension(
      current.copyWith(manifest: {...current.manifest, 'prompt': '应用版本'}),
    );
    agent.resumeExternalSources();
    await until(() => agent.sourceStatus('conflict').contains('均有修改'));
    expect(
      agent.extensions.firstWhere((e) => e.id == 'conflict').prompt,
      '应用版本',
    );
    expect(await file.readAsString(), contains('磁盘版本'));
    await agent.reloadExtensionSource('conflict');
    expect(
      agent.extensions.firstWhere((e) => e.id == 'conflict').prompt,
      '磁盘版本',
    );
  });
  test('应用中保存后同步到原目录，重启自动加载磁盘上的后续修改；ID大小写不串目录', () async {
    for (final id in ['CON', 'con']) {
      await agent.saveExtension(
        AgentExtension.parse(
          jsonEncode({
            'schema': 1,
            'id': id,
            'name': '$id Skill',
            'kind': 'skill',
            'prompt': 'initial',
          }),
        ),
      );
    }
    final upper = await agent.extensionSourceDirectory('CON'),
        lower = await agent.extensionSourceDirectory('con');
    expect(upper.path.toLowerCase(), isNot(lower.path.toLowerCase()));
    var current = agent.extensions.firstWhere((e) => e.id == 'CON');
    await agent.saveExtension(
      current.copyWith(manifest: {...current.manifest, 'prompt': '应用内保存'}),
    );
    final file = File(p.join(upper.path, 'skill.json'));
    await until(() => file.readAsStringSync().contains('应用内保存'));
    final store = agent.store, root = agent.externalSourcesRoot;
    await agent.shutdown();
    agent.dispose();
    final disk = Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    )..['prompt'] = '退出时由外部编辑器修改';
    await file.writeAsString(jsonEncode(disk), flush: true);
    agent = AgentController(store: store, externalSourcesRoot: root);
    await agent.initialize();
    expect(
      agent.extensions.firstWhere((e) => e.id == 'CON').prompt,
      '退出时由外部编辑器修改',
    );
    expect(agent.extensions.firstWhere((e) => e.id == 'con').prompt, 'initial');
  });
  test(
    '真实JS原包外部编辑超过旧1MB预览限制的源文件，仍热加载且坏代码保留',
    () async {
      await agent.saveExtension(
        fixture().copyWith(
          enabled: true,
          settings: {'API_KEY': 'fixture-private'},
        ),
      );
      final directory = await agent.extensionSourceDirectory('fixture'),
          file = File(p.join(directory.path, 'lib', 'value.js'));
      final code =
          "export const answer='磁盘JS';\n/*${List.filled(1024 * 1024 + 16, 'x').join()}*/";
      await file.writeAsString(code, flush: true);
      await agent.reloadExtensionSource('fixture');
      final current = agent.extensions.firstWhere((e) => e.id == 'fixture');
      final result = await agent.packages.run(
        manifest: current.manifest,
        settings: current.config,
        operation: 'tool',
        args: {'id': 'run', 'args': <String, dynamic>{}},
        active: () => true,
      );
      expect(result['content'], '磁盘JS');
      expect(current.config['API_KEY'], 'fixture-private');
      await file.writeAsString('export const answer = ;', flush: true);
      await expectLater(
        agent.reloadExtensionSource('fixture'),
        throwsA(isA<AgentException>()),
      );
      expect(await file.readAsString(), 'export const answer = ;');
      expect(
        agent.extensionFiles('fixture').readText('index.js'),
        contains('registerTool'),
      );
    },
    skip: Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
        ? '需要测试引擎'
        : false,
  );
  test('打开位置传递完整路径参数，不经shell；Windows Explorer返回1也视为已打开', () async {
    final folder = Directory(p.join(temporary.path, '带 空格 & 字符'));
    await folder.create();
    final file = File(p.join(folder.path, 'skill.json'));
    await file.writeAsString('{}');
    String program = '';
    List<String> args = [];
    await DesktopFileLocation.open(
      file.path,
      selectFile: true,
      system: 'windows',
      run: (name, arguments) async {
        program = name;
        args = arguments;
        return ProcessResult(0, 1, '', '');
      },
    );
    expect(program, 'explorer.exe');
    expect(args, ['/select,${p.normalize(p.absolute(file.path))}']);
    await DesktopFileLocation.open(
      folder.path,
      system: 'linux',
      run: (name, arguments) async {
        expect(name, 'xdg-open');
        expect(arguments, [folder.absolute.path]);
        return ProcessResult(0, 0, '', '');
      },
    );
  });
}
