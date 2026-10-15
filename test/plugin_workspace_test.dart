import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';
import 'package:qq_bot_manager/services/plugin_workspace.dart';

void main() {
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
