import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/services/data_backup_archive.dart';
import 'package:qq_bot_manager/services/data_migration_service.dart';
import 'package:qq_bot_manager/services/storage_service.dart';

class FailingRestoreAgentStore extends AgentStore {
  bool fail = true;
  FailingRestoreAgentStore() : super.memory();
  @override
  Future<void> replaceAllData(Map<String, String> values) async {
    if (fail) {
      fail = false;
      throw StateError('fixture write failure');
    }
    await super.replaceAllData(values);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StorageService storage;
  late AgentStore agent;
  late DataMigrationService migration;
  Future<void> prepare(String folder, {AgentStore? store}) async {
    final dir = Directory(p.join(root.path, folder));
    await dir.create(recursive: true);
    Hive.init(dir.path);
    SharedPreferences.setMockInitialValues({
      'test-list': ['甲', '乙'],
      'test-int': 42,
      'test-double': 1.5,
      'test-bool': true,
    });
    storage = StorageService();
    await storage.init();
    agent = store ?? AgentStore();
    migration = DataMigrationService(
      storage: storage,
      agent: agent,
      dataRoot: dir,
      workspaceRoot: Directory(p.join(dir.path, 'plugin_workspace')),
    );
  }

  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp(
      'qqm-data-backup-test-',
    );
    // CI's TEMP can be a junction (Windows) or /var -> /private/var (macOS).
    // Supply the real data root, as required by the restore containment checks.
    root = Directory(await temporary.resolveSymbolicLinks());
    await prepare('source');
  });
  tearDown(() async {
    await agent.close();
    await Hive.close();
    migration.dispose();
    expect(p.basename(root.path), startsWith('qqm-data-backup-test-'));
    await root.delete(recursive: true);
  });
  Future<void> seed(String label) async {
    for (final app in ['10001', '10002']) {
      await storage.saveBotConfig(
        BotConfig(appId: app, clientSecret: 'fixture-$label-$app'),
      );
      storage.selectChatAccount(app);
      await storage.saveMessage(
        MessageModel(
          id: 'm',
          sessionId: 's',
          senderId: 'u',
          senderName: label,
          content: '$label-$app',
          messageType: 0,
          timestamp: DateTime(2026, 10, 26),
        ),
      );
    }
    await storage.writePluginData('fixture-scope', {
      'points': 17,
      'label': label,
    });
    await agent.open();
    await agent.put('provider:fixture', {
      'apiKey': 'fixture-model-$label',
      'model': 'fixture',
    });
    await agent.put('extension:fixture', {
      'manifest': {
        'id': 'fixture',
        'files': {
          'index.js': base64Encode(utf8.encode('export const label="$label";')),
        },
      },
      'settings': {'voice': label},
      'secrets': {'API_KEY': 'fixture-addon-key'},
    });
    await agent.put('history:fixture', {
      'messages': [
        {'text': label},
      ],
    });
    await agent.put('js-volume:fixture:scope', {
      'files': {
        '/data/state.json': {'data': label},
      },
    });
    final file = File(
      p.join(migration.workspaceRoot.path, 'demo', 'nested', 'source.ht'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(label);
    final history = File(
      p.join(migration.workspaceRoot.path, '_history', '123__demo__source.ht'),
    );
    await history.parent.create();
    await history.writeAsString('$label-history');
  }

  test('共享QQ回复序号持久化到完整备份，重开后保留并清理过期项', () async {
    await storage.writePluginData('official-reply:expired-fixture', {
      'sequence': 5,
      'expiresAt': 0,
    });
    await storage.saveOfficialReplySequence('fixture-counter', 3);
    expect(storage.officialReplySequence('fixture-counter'), 3);
    expect(
      await storage.readPluginData('official-reply:expired-fixture'),
      isEmpty,
    );
    final exported = await storage.exportAllData();
    expect(
      exported['boxes']['plugin_data'].keys,
      contains('official-reply:fixture-counter'),
    );
    await agent.close();
    await Hive.close();
    migration.dispose();
    await prepare('source');
    expect(storage.officialReplySequence('fixture-counter'), 3);
  });

  test('完整ZIP涵盖两个官机账号、所有偏好、Agent密钥/源码/历史/VFS和工作区历史', () async {
    await seed('源');
    final expected = await storage.exportAllData(),
        agentExpected = await agent.exportAllData();
    final bytes = await migration.exportZip(),
        snapshot = DataBackupArchive.decode(bytes);
    expect(snapshot.official, expected);
    expect(snapshot.agent, agentExpected);
    expect(
      snapshot.workspace.keys,
      containsAll(['demo/nested/source.ht', '_history/123__demo__source.ht']),
    );
    expect(snapshot.counts['messages'], 2);
    expect(snapshot.official['preferences']['test-list'], ['甲', '乙']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('test-int'), 42);
    final restored = DataBackupArchive.decode(
      DataBackupArchive.encode(snapshot),
    );
    expect(restored.agent, agentExpected);
  });
  test('导入先校验并自动保存当前数据，重启后完整替换且不混入原数据', () async {
    await seed('源');
    final bytes = await migration.exportZip(),
        source = DataBackupArchive.decode(bytes);
    await agent.close();
    await Hive.close();
    migration.dispose();
    await prepare('target');
    await seed('旧');
    final old = await storage.exportAllData();
    var paused = 0;
    migration.beforeRestore = () async {
      paused++;
    };
    await migration.stageRestore(bytes);
    expect(paused, 1);
    expect(migration.restartRequired, true);
    expect(await storage.exportAllData(), old);
    final recovery = DataBackupArchive.decode(
      await File(migration.recoveryPath).readAsBytes(),
    );
    expect(recovery.official, old);
    await agent.close();
    await Hive.close();
    final dir = Directory(p.join(root.path, 'target'));
    Hive.init(dir.path);
    storage = StorageService();
    await storage.init();
    agent = AgentStore();
    migration.dispose();
    migration = DataMigrationService(
      storage: storage,
      agent: agent,
      dataRoot: dir,
      workspaceRoot: Directory(p.join(dir.path, 'plugin_workspace')),
    );
    expect(await migration.applyPendingRestore(), contains('恢复成功'));
    expect(await storage.exportAllData(), source.official);
    expect(await agent.exportAllData(), source.agent);
    expect(
      await File(
        p.join(migration.workspaceRoot.path, 'demo/nested/source.ht'),
      ).readAsString(),
      '源',
    );
    expect(await migration.applyPendingRestore(), isNull);
  });
  test('中途写入失败自动回滚所有表、偏好、Agent数据和文件', () async {
    await seed('源');
    final bytes = await migration.exportZip();
    await agent.close();
    await Hive.close();
    migration.dispose();
    await prepare('target', store: FailingRestoreAgentStore());
    await seed('旧');
    final old = await storage.exportAllData(),
        oldAgent = await agent.exportAllData();
    await migration.stageRestore(bytes);
    expect(await migration.applyPendingRestore(), contains('已还原'));
    expect(await storage.exportAllData(), old);
    expect(await agent.exportAllData(), oldAgent);
    expect(
      await File(
        p.join(migration.workspaceRoot.path, 'demo/nested/source.ht'),
      ).readAsString(),
      '旧',
    );
  });
  test('进程中断的恢复会在下次启动回滚，损坏的待恢复文件不会阻塞正常使用', () async {
    await seed('旧');
    final bytes = await migration.exportZip();
    await migration.stageRestore(bytes);
    final journal = File(p.join(migration.migrationRoot.path, 'pending.json'));
    final data = Map<String, dynamic>.from(
      jsonDecode(await journal.readAsString()) as Map,
    );
    await journal.writeAsString(jsonEncode({...data, 'phase': 'applying'}));
    await storage.writePluginData('fixture-scope', {'label': '部分覆盖'});
    expect(await migration.applyPendingRestore(), contains('中断'));
    expect((await storage.readPluginData('fixture-scope'))['label'], '旧');
    migration.restartRequired = false;
    await migration.stageRestore(bytes);
    final pending = jsonDecode(await journal.readAsString()) as Map;
    await File(
      p.join(migration.migrationRoot.path, 'incoming-${pending['id']}.zip'),
    ).writeAsString('broken');
    expect(await migration.applyPendingRestore(), contains('已取消恢复'));
    expect((await storage.readPluginData('fixture-scope'))['label'], '旧');
  });
  test('普通ZIP、路径穿越、重复路径、篡改和夸大的解压大小均在恢复前拒绝', () async {
    Uint8List zip(List<ArchiveFile> files) {
      final archive = Archive();
      for (final f in files) {
        archive.addFile(f);
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    for (final bad in [
      zip([
        ArchiveFile('../escape.txt', 1, [1]),
      ]),
      zip([
        ArchiveFile('unknown.json', 2, [123, 125]),
      ]),
    ]) {
      await expectLater(migration.inspectZip(bad), throwsFormatException);
      await expectLater(migration.stageRestore(bad), throwsFormatException);
    }
    await seed('源');
    final valid = await migration.exportZip();
    final archive = ZipDecoder().decodeBytes(valid),
        manifest = archive.findFile('manifest.json')!;
    final metadata =
        jsonDecode(utf8.decode(manifest.content as List<int>)) as Map;
    (metadata['entries'] as Map)['agent.json']['sha256'] = '0' * 64;
    final changed = utf8.encode(jsonEncode(metadata));
    final tampered = zip([
      for (final file in archive)
        file.name == 'manifest.json'
            ? ArchiveFile(file.name, changed.length, changed)
            : file,
    ]);
    expect(() => DataBackupArchive.decode(tampered), throwsFormatException);
    final bomb = Uint8List.fromList(valid), view = ByteData.sublistView(bomb);
    for (var i = 0; i < bomb.length - 46; i++) {
      if (view.getUint32(i, Endian.little) == 0x02014b50) {
        view.setUint32(
          i + 24,
          DataBackupArchive.maxExpandedBytes + 1,
          Endian.little,
        );
        break;
      }
    }
    expect(() => DataBackupArchive.decode(bomb), throwsFormatException);
    expect(migration.restartRequired, false);
  });
  test('完整迁移外部编辑的真实源码目录，包括未通过语法检查的草稿和同步记录', () async {
    final sources = Directory(p.join(migration.dataRoot.path, 'agent_sources'));
    final draft = File(p.join(sources.path, 'example-12345678', 'index.js'));
    final state = File(p.join(sources.path, '.state', 'example-12345678.json'));
    await draft.parent.create(recursive: true);
    await draft.writeAsString('export function { // 尚未写完');
    await state.parent.create(recursive: true);
    await state.writeAsString('{"schema":1,"revision":"fixture"}');
    final bytes = await migration.exportZip(),
        data = await migration.inspectZip(bytes);
    expect(data.counts['agentSourceFiles'], 2);
    expect(
      utf8.decode(data.agentWorkspace['example-12345678/index.js']!),
      contains('尚未写完'),
    );
    await agent.close();
    await Hive.close();
    await prepare('target');
    final target = File(
      p.join(migration.dataRoot.path, 'agent_sources', 'old', 'obsolete.js'),
    );
    await target.parent.create(recursive: true);
    await target.writeAsString('before restore');
    await migration.stageRestore(bytes);
    await migration.applyPendingRestore();
    final restored = File(
      p.join(
        migration.dataRoot.path,
        'agent_sources',
        'example-12345678',
        'index.js',
      ),
    );
    expect(await restored.readAsString(), 'export function { // 尚未写完');
    expect(await target.exists(), isFalse);
    final before = await migration.inspectZip(
      await migration.readZip((await migration.recoveryBackups()).single),
    );
    expect(
      utf8.decode(before.agentWorkspace['old/obsolete.js']!),
      'before restore',
    );
  });

  test('原版Node插件源码、账户配置和数据完整恢复，不复制运行库与原生依赖', () async {
    final nodeRoot = Directory(p.join(migration.dataRoot.path, 'node_plugins'));
    final values = {
      'packages/node_demo/source/index.js': 'export class Demo {}',
      'packages/node_demo/source/node_modules/native/index.js':
          'platform binary',
      'packages/node_demo/accounts/app/plugins/demo/settings.yaml':
          'label: fixture',
      'packages/node_demo/accounts/app/plugins/demo/data/count.txt': '7',
      'host/server.mjs': 'managed runtime',
    };
    for (final entry in values.entries) {
      final file = File(p.join(nodeRoot.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final bytes = await migration.exportZip();
    final exported = await migration.inspectZip(bytes);
    expect(exported.counts['nodePluginFiles'], 3);
    await agent.close();
    await Hive.close();
    migration.dispose();
    await prepare('target');
    await migration.stageRestore(bytes);
    await migration.applyPendingRestore();
    final restored = Directory(p.join(migration.dataRoot.path, 'node_plugins'));
    expect(
      await File(
        p.join(restored.path, 'packages/node_demo/source/index.js'),
      ).readAsString(),
      'export class Demo {}',
    );
    expect(
      await File(
        p.join(
          restored.path,
          'packages/node_demo/accounts/app/plugins/demo/settings.yaml',
        ),
      ).readAsString(),
      'label: fixture',
    );
    expect(
      await File(
        p.join(
          restored.path,
          'packages/node_demo/accounts/app/plugins/demo/data/count.txt',
        ),
      ).readAsString(),
      '7',
    );
    expect(
      await Directory(
        p.join(restored.path, 'packages/node_demo/source/node_modules'),
      ).exists(),
      false,
    );
    expect(await Directory(p.join(restored.path, 'host')).exists(), false);
  });

  test('跨设备迁移自定义表情的原图字节，恢复到新目录并重写旧路径', () async {
    final image = File(p.join(root.path, 'selected-image.png'));
    final original = Uint8List.fromList([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      1,
      2,
      3,
    ]);
    await image.writeAsBytes(original);
    await storage.saveEmoji(
      EmojiItem(
        id: 'custom-local',
        name: '本地图片',
        url: image.path,
        localPath: image.path,
        isCustom: true,
      ),
    );
    final bytes = await migration.exportZip(),
        decoded = await migration.inspectZip(bytes);
    expect(decoded.assets.length, 1);
    expect(decoded.assets.values.single, original);
    await agent.close();
    await Hive.close();
    await image.delete();
    await prepare('target');
    await migration.stageRestore(bytes);
    await migration.applyPendingRestore();
    final restored = storage.getEmojis().singleWhere(
      (e) => e.id == 'custom-local',
    );
    expect(restored.localPath, isNot(image.path));
    expect(restored.url, restored.localPath);
    expect(p.isWithin(migration.dataRoot.path, restored.localPath!), isTrue);
    expect(await File(restored.localPath!).readAsBytes(), original);
    expect(
      (await migration.inspectZip(
        await DataMigrationService(
          storage: storage,
          agent: agent,
          dataRoot: migration.dataRoot,
          workspaceRoot: migration.workspaceRoot,
        ).exportZip(),
      )).assets.values.single,
      original,
    );
    final missing = DataBackupArchive.encode(
      BackupData(
        decoded.official,
        decoded.agent,
        decoded.workspace,
        decoded.metadata,
      ),
    );
    expect(() => DataBackupArchive.decode(missing), throwsFormatException);
  });

  test('没有待恢复任务时不会额外调用系统目录插件，导出时才解析一次工作区', () async {
    var calls = 0;
    final deferred = DataMigrationService(
      storage: storage,
      agent: agent,
      dataRoot: migration.dataRoot,
      workspaceRootResolver: () async {
        calls++;
        return migration.workspaceRoot;
      },
    );
    expect(await deferred.applyPendingRestore(), isNull);
    expect(calls, 0);
    await deferred.exportZip();
    await deferred.exportZip();
    expect(calls, 1);
    deferred.dispose();
  });

  test('导出不会启动Agent连接，源目录链接不会被跟随', () async {
    expect(agent.isOpen, false);
    await migration.exportZip();
    expect(agent.isOpen, true);
    if (!Platform.isWindows) {
      await Link(
        p.join(migration.workspaceRoot.path, 'outside'),
      ).create(root.path);
      await expectLater(migration.exportZip(), throwsFormatException);
    }
  });
}
