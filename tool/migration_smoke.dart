// End-to-end local server backup/restore with synthetic data only. No QQ login
// or real model request, and no files from the user's application directory.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/runtime/assets_server.dart';
import 'package:qq_bot_manager/services/data_backup_archive.dart';
import 'package:qq_bot_manager/services/data_migration_service.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import '../server/src/manager_server.dart';
import 'server_smoke.dart' show OfflineBot, check;
import 'support/server_fixture_api.dart';

Future<void> main() async {
  final data = await Directory.systemTemp.createTemp('qqm-migration-smoke-'),
      http = HttpClient();
  ManagerServer? server;
  try {
    rootBundle.root = Directory.current;
    Hive.init(data.path);
    final storage = StorageService();
    await storage.init();
    await storage.saveBotConfig(
      BotConfig(appId: '10000001', clientSecret: 'synthetic-bot-secret'),
    );
    final agent = AgentStore();
    await agent.open();
    await agent.put('provider:test', {
      'id': 'test',
      'name': 'fixture',
      'model': 'test',
      'apiKey': 'synthetic-key',
    });
    await agent.put(
      'extension:test',
      AgentExtension.parse(
        jsonEncode({
          'schema': 1,
          'id': 'test',
          'name': '可编辑Skill',
          'kind': 'skill',
          'prompt': '旧提示词',
        }),
      ).copyWith(secrets: {'KEY': 'synthetic-ext-key'}).toJson(),
    );
    final file = File(
      p.join(data.path, 'plugin_workspace', 'demo', 'src', 'a.ht'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString('original');
    final migration = DataMigrationService(
      storage: storage,
      agent: agent,
      dataRoot: data,
      workspaceRoot: Directory(p.join(data.path, 'plugin_workspace')),
    );
    final plugins = PluginManager(storage);
    await plugins.init();
    final bot = OfflineBot(storage, apiService: ServerFixtureApi());
    server = await ManagerServer.start(
      bot: bot,
      plugins: plugins,
      storage: storage,
      data: data,
      assets: Directory.current,
      port: 0,
      migration: migration,
    );
    var origin = server.address, entrance = '';
    Cookie? cookie;
    Future<({int code, Uint8List bytes, dynamic json})> request(
      String route, {
      Object? body,
      bool raw = false,
      bool confirm = false,
      bool header = true,
      String? foreign,
    }) async {
      final r = await http.openUrl(
        body == null ? 'GET' : 'POST',
        origin.resolve('$entrance$route'),
      );
      if (header) r.headers.set('X-QQM-Request', '1');
      if (confirm) r.headers.set('X-QQM-Confirm-Restore', '1');
      if (foreign != null) r.headers.set('Origin', foreign);
      if (cookie != null) r.cookies.add(cookie!);
      if (body != null) {
        if (raw) {
          r.add(body as List<int>);
        } else {
          r.headers.contentType = ContentType.json;
          r.write(jsonEncode(body));
        }
      }
      final response = await r.close();
      if (response.cookies.isNotEmpty) cookie = response.cookies.last;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      dynamic value;
      try {
        value = jsonDecode(utf8.decode(bytes));
      } catch (_) {}
      return (code: response.statusCode, bytes: bytes, json: value);
    }

    check(
      (await request('/api/migration/export', body: {})).code == 401,
      '未登录不能导出包含密钥的备份',
    );
    final token = (await File(
      p.join(data.path, 'setup-token.txt'),
    ).readAsString()).trim();
    check(
      (await request(
            '/api/setup',
            body: {
              'token': token,
              'password': 'fixture-migration-password',
              'confirmation': 'fixture-migration-password',
              'entrance': 'migration-test-entrance',
            },
          )).code ==
          200,
      '初始化本地测试管理员',
    );
    entrance = '/migration-test-entrance';
    check(
      (await request('/api/migration/export', body: {}, header: false)).code ==
          403,
      '导出需要自定义请求头',
    );
    check(
      (await request(
            '/api/migration/export',
            body: {},
            foreign: 'https://attacker.invalid',
          )).code ==
          403,
      '跨站不能导出备份',
    );
    check(
      (await request(
            '/api/migration/recovery?file=../../admin-auth.json',
          )).code ==
          400,
      '恢复备份下载不能越界',
    );
    final workspace = (await request(
      '/api/agent/extension/files?id=test',
    )).json;
    final source =
        jsonDecode(utf8.decode(base64Decode(workspace['files']['skill.json'])))
            as Map;
    source['prompt'] = '编辑后提示词';
    final save = await request(
      '/api/agent/extension/files/save',
      body: {
        'id': 'test',
        'revision': workspace['revision'],
        'files': {'skill.json': base64Encode(utf8.encode(jsonEncode(source)))},
      },
    );
    check(save.code == 200, 'Linux支持Skill完整清单编辑');
    check(
      (await request(
            '/api/agent/extension/files/save',
            body: {
              'id': 'test',
              'revision': workspace['revision'],
              'files': workspace['files'],
            },
          )).code ==
          400,
      '旧网页不能覆盖新的源码',
    );
    final backup = await request('/api/migration/export', body: {});
    check(backup.code == 200, '完整ZIP导出');
    final decoded = DataBackupArchive.decode(backup.bytes);
    check(
      decoded.agent['provider:test']!.contains('synthetic-key'),
      '模型密钥也在完整迁移中',
    );
    check(
      decoded.agent['extension:test']!.contains('synthetic-ext-key'),
      '插件密钥也在完整迁移中',
    );
    check(decoded.workspace['demo/src/a.ht'] != null, '包含工作区源码');
    final auth = File(p.join(data.path, 'admin-auth.json')),
        authDigest = sha256
            .convert(
              await File(p.join(data.path, 'admin-auth.json')).readAsBytes(),
            )
            .toString();
    check(
      !(utf8.decode(backup.bytes, allowMalformed: true).contains('admin-auth')),
      '备份不拷贝服务器管理入口',
    );
    check(
      (await request(
            '/api/migration/restore',
            body: backup.bytes,
            raw: true,
          )).code ==
          400,
      '恢复必须显式确认',
    );
    check(
      (await request(
            '/api/migration/inspect',
            body: backup.bytes,
            raw: true,
          )).code ==
          200,
      '导入先预览校验',
    );
    await file.writeAsString('new-before-restore');
    await agent.put('provider:test', {
      'id': 'test',
      'apiKey': 'new-before-restore',
    });
    final staged = await request(
      '/api/migration/restore',
      body: backup.bytes,
      raw: true,
      confirm: true,
    );
    check(
      staged.code == 200 && staged.json['restartRequired'] == true,
      '恢复准备完成',
    );
    check(
      (await request('/api/migration/status')).json['restartRequired'] == true,
      '网页显示待重启状态',
    );
    check(
      (await request('/api/config', body: {'appId': '20000002'})).code == 409,
      '迁移准备后不能继续修改数据',
    );
    check((await request('/api/agent/state')).code == 409, '迁移准备后不会重新启动Agent');
    check(await file.readAsString() == 'new-before-restore', '重启前不替换活动数据');
    await server.close();
    server = null;
    await Hive.close();
    Hive.init(data.path);
    final restored = StorageService();
    await restored.init();
    final restoredAgent = AgentStore();
    final next = DataMigrationService(
      storage: restored,
      agent: restoredAgent,
      dataRoot: data,
      workspaceRoot: Directory(p.join(data.path, 'plugin_workspace')),
    );
    check((await next.applyPendingRestore())!.contains('成功'), '服务重启完整恢复');
    check(await file.readAsString() == 'original', '源码恢复正确');
    check(
      restoredAgent.get('provider:test')!['apiKey'] == 'synthetic-key',
      'Agent密钥恢复正确',
    );
    check(
      restored.getBotConfig().clientSecret == 'synthetic-bot-secret',
      '官机密钥恢复正确',
    );
    check(
      sha256.convert(await auth.readAsBytes()).toString() == authDigest,
      '服务器密码和安全入口保持不变',
    );
    check((await next.recoveryBackups()).length == 1, '保留一份恢复前完整备份');
    final recovery = await next.inspectZip(
      await next.readZip((await next.recoveryBackups()).single),
    );
    check(
      recovery.agent['provider:test']!.contains('new-before-restore'),
      '自动备份是恢复前的最新数据',
    );
    await restoredAgent.close();
    await Hive.close();
    stdout.writeln(
      'PASS: 完整ZIP跨工作区、认证/来源限制、网页Skill源码编辑、冲突保护、确认恢复、重启应用和恢复前备份；服务器登录与入口保留。',
    );
  } finally {
    await server?.close();
    http.close(force: true);
    await Hive.close();
    check(p.basename(data.path).startsWith('qqm-migration-smoke-'), '临时目录范围');
    await data.delete(recursive: true);
  }
}
