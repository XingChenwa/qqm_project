import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';
import 'package:qq_bot_manager/services/plugin_workspace.dart';

void main() {
  test('两个工作台同时保存时只有首个成功，后到者不能覆盖', () async {
    final root = await Directory.systemTemp.createTemp(
      'qqm-plugin-concurrent-',
    );
    addTearDown(() => root.delete(recursive: true));
    final first = PluginWorkspace(root), second = PluginWorkspace(root);
    await first.write('my_plugin', 'plugin.json', 'original');
    final results = await Future.wait([
      first
          .write('my_plugin', 'plugin.json', 'first', expected: 'original')
          .then((_) => true)
          .catchError((Object _) => false),
      second
          .write('my_plugin', 'plugin.json', 'second', expected: 'original')
          .then((_) => true)
          .catchError((Object _) => false),
    ]);
    expect(results, [true, false]);
    expect(await first.read('my_plugin', 'plugin.json'), 'first');
    expect(await first.history(), hasLength(1));
  });
  test('子目录、重命名、历史恢复及并发保存保护不覆盖用户文件', () async {
    final root = await Directory.systemTemp.createTemp('qqm-plugin-files-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = PluginWorkspace(root);
    await workspace.createProject('my_files');
    await workspace.createFolder('my_files', 'docs');
    await workspace.write('my_files', 'docs/说明.md', '第一版', createOnly: true);
    await expectLater(
      workspace.write('my_files', 'docs/说明.md', '', createOnly: true),
      throwsA(isA<PluginManifestException>()),
    );
    await expectLater(
      workspace.createProject('my_files'),
      throwsA(isA<PluginManifestException>()),
    );
    await workspace.write('my_files', 'docs/说明.md', '第二版', expected: '第一版');
    await expectLater(
      workspace.write('my_files', 'docs/说明.md', '冲突', expected: '第一版'),
      throwsA(isA<PluginManifestException>()),
    );
    expect(await workspace.read('my_files', 'docs/说明.md'), '第二版');
    await workspace.renameFile('my_files', 'docs/说明.md', 'source/notes.txt');
    expect(await workspace.files('my_files'), ['source/notes.txt']);
    await workspace.deleteFile('my_files', 'source/notes.txt');
    expect(await workspace.files('my_files'), isEmpty);
    final history = await workspace.history();
    expect(history, hasLength(2));
    await workspace.restore(history.first, 'my_files', 'restored.txt');
    expect(await workspace.read('my_files', 'restored.txt'), '第二版');
    await expectLater(
      workspace.restore(history.first, 'my_files', 'restored.txt'),
      throwsA(isA<PluginManifestException>()),
    );
  });
  test('拒绝逃逸、系统保留名、超大文件和链接路径', () async {
    final root = await Directory.systemTemp.createTemp('qqm-plugin-boundary-');
    final outside = await Directory.systemTemp.createTemp(
      'qqm-plugin-outside-',
    );
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => outside.delete(recursive: true));
    final workspace = PluginWorkspace(root);
    await workspace.createProject('my_safe');
    for (final path in [
      '../x.json',
      '/x.json',
      'C:/x.json',
      r'docs\x.json',
      'CON.txt',
      'docs/../x.json',
      'a/b/c/d/e/f/g.txt',
      'x.exe',
      '.hidden.json',
    ]) {
      await expectLater(
        workspace.write('my_safe', path, 'bad'),
        throwsA(isA<PluginManifestException>()),
      );
    }
    await expectLater(
      workspace.write(
        'my_safe',
        'large.txt',
        'x' * (PluginWorkspace.maxBytes + 1),
      ),
      throwsA(isA<PluginManifestException>()),
    );
    final link = Link('${root.path}/my_safe/linked');
    try {
      await link.create(outside.path);
    } on FileSystemException {
      markTestSkipped('当前 Windows 不允许创建符号链接；其余边界断言已完成。');
      return;
    }
    await expectLater(
      workspace.write('my_safe', 'linked/outside.json', 'bad'),
      throwsA(isA<PluginManifestException>()),
    );
    expect(await File('${outside.path}/outside.json').exists(), false);
    await link.delete();
  });
  test('命令草稿生成可安装清单，文件不能逃出插件目录', () async {
    final root = await Directory.systemTemp.createTemp('qqm-plugin-workspace-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = PluginWorkspace(root);
    final source = PluginWorkspace.rulesManifest(
      id: 'my_hello',
      name: '问候',
      description: '一条命令一条回复',
      commands: [
        PluginCommandDraft(value: 'hello', reply: '你好，{{sender_name}}'),
      ],
    );
    final definition = PluginManifest.parse(source);
    expect(definition.id, 'my_hello');
    expect(definition.runtime, 'rules');
    await workspace.write('my_hello', 'plugin.json', source);
    await workspace.write('my_hello', 'readme.md', '# 问候');
    expect(await workspace.files('my_hello'), ['plugin.json', 'readme.md']);
    expect(await workspace.read('my_hello', 'plugin.json'), source);
    await expectLater(
      workspace.write('my_hello', '../plugin.json', source),
      throwsA(isA<PluginManifestException>()),
    );
    await expectLater(
      workspace.write('../escape', 'plugin.json', source),
      throwsA(isA<PluginManifestException>()),
    );
  });
}
