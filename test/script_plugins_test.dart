import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/core/plugins/script_plugin.dart';
import 'package:qq_bot_manager/core/plugins/script_runner.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';
import 'package:qq_bot_manager/services/plugin_workspace.dart';

import 'support/fakes.dart';

PluginMessage event(
  String text, {
  String user = 'owner',
  String role = 'owner',
  String group = 'g1',
  String callback = '',
}) => PluginMessage(
  messageId: 'msg',
  sessionId: group,
  senderId: user,
  senderName: '测试用户',
  senderRole: role,
  content: text,
  messageType: 0,
  isGroup: true,
  isMentioned: true,
  timestamp: DateTime.now(),
  eventType: callback.isEmpty ? 'message' : 'interaction',
  callbackData: callback,
);

Map<String, dynamic> bundle(String id) {
  final data =
      jsonDecode(File('plugins/$id/plugin.json').readAsStringSync())
          as Map<String, dynamic>;
  data['script']['source'] = File('plugins/$id/main.ht').readAsStringSync();
  return data;
}

Future<PluginManager> manager(MemoryStorage storage) async {
  final result = PluginManager(
    storage,
  ); // Real cancellable isolates, not widget-test inline mode.
  addTearDown(result.dispose);
  await result.init();
  return result;
}

Future<String> reply(PluginManager host, String text, {String? id}) async {
  final result = await host.processMessage(event(text), onlyPluginId: id);
  expect(
    result,
    hasLength(1),
    reason: '$text: ${id == null ? '' : host.errorFor(id)}',
  );
  return result.single.content;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('七个随附项目均由公共脚本加载器运行，导出可复制导入且不包含本地密钥', () async {
    final host = await manager(MemoryStorage());
    expect(host.plugins, hasLength(7));
    for (final plugin in host.plugins) {
      expect(plugin, isA<ScriptPlugin>());
      expect(plugin.info.isEnabled, false);
      final source =
          jsonDecode(host.exportPlugin(plugin.info.id)) as Map<String, dynamic>;
      expect(source['script']['source'], contains('function main'));
      source['id'] = 'copy_${plugin.info.id}';
      final copy = await host.installPlugin(jsonEncode(source));
      expect(copy.isEnabled, false);
      expect(
        await host.enablePlugin(copy.id),
        true,
        reason: host.errorFor(copy.id),
      );
    }
    expect(
      await reply(host, '/ping', id: 'copy_example_plugin'),
      contains('pong'),
    );
  });

  test('修改导出的内置源码无需改内核或编译，替换停用并跨重启保留自定义版本', () async {
    final storage = MemoryStorage();
    final host = await manager(storage);
    final source =
        jsonDecode(host.exportPlugin('example_plugin')) as Map<String, dynamic>;
    source['script']['source'] =
        "function main(ctx) { if (ctx.phase == 'enable') { return null } return '开发者修改生效' }";
    await host.installPlugin(jsonEncode(source), replaceExisting: true);
    expect(host.plugins.last.info.isCustomized, true);
    expect(host.plugins.last.info.isEnabled, false);
    expect(await host.enablePlugin('example_plugin'), true);
    expect(await reply(host, '/anything', id: 'example_plugin'), '开发者修改生效');
    final restarted = await manager(storage);
    expect(
      await reply(restarted, '/anything', id: 'example_plugin'),
      '开发者修改生效',
    );
  });

  test('脚本运行时签到只加一次分，排行榜排序并按 AppID 和会话隔离', () async {
    final storage = MemoryStorage(config: validConfig());
    final host = await manager(storage);
    expect(await host.enablePlugin('daily_club'), true);
    final results = await Future.wait([
      host.processMessage(event('/签到')),
      host.processMessage(event('/签到')),
    ]);
    expect(
      results.expand((r) => r).where((r) => r.content.contains('签到成功')),
      hasLength(1),
    );
    expect(await reply(host, '/积分', id: 'daily_club'), contains('10 分'));
    expect(await reply(host, '/排行', id: 'daily_club'), contains('1. 测试用户'));
    final fortune = await reply(host, '/今日运势', id: 'daily_club');
    expect(await reply(host, '/今日运势', id: 'daily_club'), fortune);
    expect(await reply(host, '/抽签', id: 'daily_club'), contains('仅供娱乐'));
    await storage.saveBotConfig(validConfig()..appId = 'another-app');
    expect(await reply(host, '/积分', id: 'daily_club'), contains('0 分'));
    expect(storage.pluginData, hasLength(2));
  });

  test('脚本猜数字与投票完整状态、改票、管理员结束和旧按钮保护', () async {
    final storage = MemoryStorage();
    final host = await manager(storage);
    await host.updatePluginConfig('group_games', {'enable_buttons': true});
    expect(await host.enablePlugin('group_games'), true);
    expect(await reply(host, '/猜数字 开始', id: 'group_games'), contains('1–100'));
    final attempts = await reply(host, '/猜数字 50', id: 'group_games');
    expect(attempts, anyOf(contains('再试试'), contains('猜对')));
    final started = await host.processMessage(
      event('/投票 创建 晚餐 | 火锅 | 烧烤'),
      onlyPluginId: 'group_games',
    );
    final button = started.single.reply!.buttons.first.first;
    expect(button.data, startsWith('qqm:group_games:vote:'));
    final voted = await host.processMessage(
      event('', callback: button.data, user: 'a'),
      onlyPluginId: 'group_games',
    );
    expect(voted.single.content, contains('共 1 人参与'));
    expect(
      await reply(host, '/投票 选择 2', id: 'group_games'),
      contains('烧烤：1 票'),
    );
    expect(
      await reply(host, '/投票 选择 1', id: 'group_games'),
      contains('共 2 人参与'),
    );
    final denied = await host.processMessage(
      event('/投票 结束', user: 'other', role: 'member'),
      onlyPluginId: 'group_games',
    );
    expect(denied.single.content, contains('仅发起人'));
    expect(await reply(host, '/投票 结束', id: 'group_games'), contains('投票已结束'));
    await reply(host, '/投票 创建 新投票 | A | B', id: 'group_games');
    final stale = await host.processMessage(
      event('', callback: button.data),
      onlyPluginId: 'group_games',
    );
    expect(stale.single.content, contains('旧投票'));
  });

  test('主动权限链接使用真实数字群号、QQ和UID，按钮仅面向当前群主', () async {
    final storage = MemoryStorage(config: validConfig());
    final host = await manager(storage);
    await host.updatePluginConfig('group_authorization', {
      'robots_json': jsonEncode({
        'test-app': {'bot_qq': '123456789', 'bot_uid': 'u_actual_uid'},
      }),
    });
    expect(await host.enablePlugin('group_authorization'), true);
    final initial = await host.processMessage(
      event('/主动消息'),
      onlyPluginId: 'group_authorization',
    );
    expect(initial.single.reply!.buttons.first.first.url, false);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final result = await host.processMessage(
      event('/主动消息 938017865'),
      onlyPluginId: 'group_authorization',
    );
    final button = result.single.reply!.buttons.first.first;
    expect(button.label, '主动权限(群主使用)');
    expect(button.userIds, ['owner']);
    final url = Uri.parse(button.data);
    expect(url.host, 'club.vip.qq.com');
    expect(jsonDecode(url.queryParameters['open_kuikly_info']!), {
      'page_name': 'ai_group_service_agreement_pop_page',
      'groupCode': 938017865,
      'botUin': 123456789,
      'botUid': 'u_actual_uid',
      'screen': 1,
    });
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final denied = await host.processMessage(
      event('/主动消息 938017865', role: 'admin'),
      onlyPluginId: 'group_authorization',
    );
    expect(denied.single.content, contains('只有群主'));
  });

  test('随机脚本全部命令可以运行，非法范围有提示而不抛解释器错误', () async {
    final host = await manager(MemoryStorage());
    await host.enablePlugin('dice_plugin');
    for (final command in [
      '/roll 2d6+3',
      '/硬币 2',
      '/选择 A | B',
      '/转盘 A | B',
      '/打乱 A | B',
      '/随机数 -5 5',
      '/猜拳 石头',
      '/roll 999d9999',
    ]) {
      expect(await reply(host, command, id: 'dice_plugin'), isNotEmpty);
    }
  });

  test('工作区脚本入口可组装、预览、导出再导入；草稿和本地历史保留', () async {
    final root = await Directory.systemTemp.createTemp('qqm-script-workspace-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = PluginWorkspace(root);
    await workspace.write(
      'hello_script',
      'plugin.json',
      PluginWorkspace.scriptManifest('hello_script'),
    );
    await workspace.write(
      'hello_script',
      'main.ht',
      PluginWorkspace.helloScript,
    );
    final source = await workspace.assembleProject('hello_script');
    final host = await manager(MemoryStorage());
    expect(
      (await host.previewPlugin(source, event('/hello 测试')))!.content,
      contains('你好'),
    );
    final copy = await host.installPlugin(source);
    await host.enablePlugin(copy.id);
    expect(await reply(host, '/hello 测试', id: copy.id), contains('测试'));
    await workspace.seedProject('hello_script', source);
    expect(
      await workspace.read('hello_script', 'main.ht'),
      PluginWorkspace.helloScript,
    );
    await workspace.write(
      'hello_script',
      'main.ht',
      "function main(ctx) { return '新的回复' }",
    );
    expect(await workspace.history(), isNotEmpty);
    final next = await workspace.assembleProject('hello_script');
    await host.installPlugin(next, replaceExisting: true);
    await host.enablePlugin(copy.id);
    expect(await reply(host, '/hello', id: copy.id), '新的回复');
  });

  test('缺失入口、越界路径、未知运行时、超时及域名权限均在安装前校验', () async {
    final source = bundle('example_plugin');
    for (final modify in <void Function(Map)>[
      (s) => s['script']['source'] = 'x' * 65537,
      (s) => s['entrypoint'] = '../escape.ht',
      (s) => s['script']['hosts'] = ['127.0.0.1'],
      (s) => s['script']['hosts'] = ['example.com'],
      (s) => s['script']['timeout_ms'] = 40001,
      (s) => s['script']['unmentioned'] = {
        'prefixes': ['普通聊天'],
      },
    ]) {
      final invalid = jsonDecode(jsonEncode(source)) as Map;
      modify(invalid);
      expect(
        () => PluginManifest.parse(jsonEncode(invalid)),
        throwsA(isA<PluginManifestException>()),
      );
    }
  });

  test('真实隔离器终止死循环，停用会中断等待；错误不会提交脚本状态', () async {
    final runner = PluginScriptRunner();
    addTearDown(runner.close);
    await expectLater(
      runner.run(
        "function main(ctx) { while (true) {} }",
        {'state': {}},
        timeout: const Duration(milliseconds: 150),
      ),
      throwsStateError,
    );
    final started = Completer<void>();
    final pending = runner.run(
      "function main(ctx) async { return await http({url:'https://example.com'}) }",
      {'state': {}},
      http: (_) {
        started.complete();
        return Completer<dynamic>().future;
      },
    );
    await started.future;
    runner.close();
    await expectLater(pending, throwsStateError);
  });

  test('回复校验失败时不提交状态，重载后可以继续使用原会话数据', () async {
    final storage = MemoryStorage();
    final host = await manager(storage);
    final data =
        jsonDecode(
              File(
                'plugins/examples/hello_script/plugin.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    data['script']['source'] =
        "function main(ctx) { if (ctx.phase == 'enable') { return null } ctx.state['count']=9 return {format:'markdown',content:''} }";
    await host.installPlugin(jsonEncode(data));
    await host.enablePlugin('hello_script');
    expect(
      await host.processMessage(event('/hello'), onlyPluginId: 'hello_script'),
      isEmpty,
    );
    expect(storage.pluginData, isEmpty);
    expect(host.errorFor('hello_script'), isNotNull);
    final valid = File(
      'plugins/examples/hello_script/plugin.json',
    ).readAsStringSync();
    await host.installPlugin(valid, replaceExisting: true);
    await host.enablePlugin('hello_script');
    expect(await reply(host, '/hello', id: 'hello_script'), contains('第 1 次'));
  });

  test('单个自定义插件定义损坏不会阻止其他插件和聊天启动', () async {
    final storage = MemoryStorage();
    storage.storedPlugins['dice_plugin'] = PluginInfo(
      id: 'dice_plugin',
      name: '坏草稿',
      version: '1',
      description: '',
      directory: '',
      isCustomized: true,
      isEnabled: true,
      manifest: {'runtime': 'broken'},
    );
    final host = await manager(storage);
    expect(host.plugins, hasLength(6));
    expect(host.errorFor('dice_plugin'), isNotNull);
    expect(storage.storedPlugins['dice_plugin']!.manifest['runtime'], 'broken');
    await host.enablePlugin('example_plugin');
    expect(await reply(host, '/ping', id: 'example_plugin'), contains('pong'));
  });
}
