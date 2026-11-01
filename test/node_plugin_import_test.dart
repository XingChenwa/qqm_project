import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';
import 'package:qq_bot_manager/services/node_plugin_service.dart';
import 'package:qq_bot_manager/services/node_plugin_backup.dart';
import 'package:qq_bot_manager/ui/widgets/node_plugin_dialogs.dart';
import 'package:flutter/material.dart';
import 'support/fakes.dart';

Map<String, dynamic> metadata() => {
  'id': 'node_original_example_12345678',
  'name': '原版插件',
  'version': '1.0.0',
  'description': '原包测试',
  'author': 'developer',
  'revision': 'a' * 64,
  'entries': ['index.js'],
};

Future<void> until(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 45));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('等待原版插件回复超时');
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('原包元数据不含服务 URL、专用 API Key 或连接配置，不允许当清单直接导入', () async {
    final manifest = PluginManager.nodeManifest(metadata());
    final definition = PluginManifest.parse(jsonEncode(manifest));
    expect(definition.runtime, 'node');
    expect(definition.toInfo().isEnabled, false);
    expect(manifest.containsKey('http'), false);
    expect(definition.fields.map((f) => f.key), [
      'owner_openids',
      'allow_proactive',
    ]);
    final manager = TestPluginManager(MemoryStorage());
    addTearDown(manager.dispose);
    await manager.init();
    await expectLater(
      manager.installPlugin(jsonEncode(manifest)),
      throwsA(isA<PluginManifestException>()),
    );
    for (final entry in ['/outside.js', '../outside.js', r'C:\outside.js']) {
      final bad = PluginManager.nodeManifest({
        ...metadata(),
        'entries': [entry],
      });
      expect(
        () => PluginManifest.parse(jsonEncode(bad)),
        throwsA(isA<PluginManifestException>()),
      );
    }
  });

  test('原包备份包含源码与账户配置/数据，排除平台依赖和未修改的重复文件', () async {
    final root = await Directory.systemTemp.createTemp(
      'qqm-node-backup-fixture-',
    );
    addTearDown(() => root.delete(recursive: true));
    final files = <String, String>{
      'packages/node_example/source/index.js': 'export class A {}',
      'packages/node_example/source/package.json': '{"name":"example"}',
      'packages/node_example/source/node_modules/dependency/index.js':
          'platform dependency',
      'packages/node_example/accounts/bot/plugins/example/index.js':
          'export class A {}',
      'packages/node_example/accounts/bot/plugins/example/config/config/settings.yaml':
          'key: fixture-only',
      'packages/node_example/accounts/bot/plugins/example/data/state.json':
          '{"count":3}',
      'packages/node_example/accounts/bot/.prepared': 'cached marker',
      'host/server.mjs': 'runtime',
      'connection.json': '{"endpoint":"","token":""}',
    };
    for (final entry in files.entries) {
      final file = File(p.join(root.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final archive = await NodePluginBackup.collect(
      root,
      maxBytes: 1000000,
      maxEntries: 1000,
    );
    expect(archive.keys, contains('packages/node_example/source/index.js'));
    expect(
      archive.keys,
      contains(
        'packages/node_example/accounts/bot/plugins/example/config/config/settings.yaml',
      ),
    );
    expect(
      archive.keys,
      contains(
        'packages/node_example/accounts/bot/plugins/example/data/state.json',
      ),
    );
    expect(
      archive.keys.any(
        (p) =>
            p.contains('node_modules') ||
            p.endsWith('.prepared') ||
            p.startsWith('host/'),
      ),
      false,
    );
    expect(
      archive.keys.contains(
        'packages/node_example/accounts/bot/plugins/example/index.js',
      ),
      false,
    );
  });

  for (final width in [360.0, 1000.0]) {
    testWidgets('原包导入界面 ${width.toInt()} 宽支持 ZIP/JS/GitHub，保留独立运行环境设置', (
      tester,
    ) async {
      final root = Directory.systemTemp.createTempSync('qqm-node-ui-fixture-');
      final service = NodePluginService(root);
      final manager = TestPluginManager(MemoryStorage())
        ..nodePackages = service;
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        manager.dispose();
        root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => NodePackageImportDialog(manager: manager),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('选择原版 ZIP / JS'), findsOneWidget);
      expect(find.byKey(const ValueKey('node-repository-url')), findsOneWidget);
      expect(find.text('Node 运行环境'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    });
  }

  test(
    '真实 Node 运行器：直接导入 JS 到原工作台，默认关闭，重载源码后生效',
    () async {
      final cache = Platform.environment['QQM_NODE_HOST_CACHE'];
      if (cache == null ||
          !await Directory(p.join(cache, 'node_modules')).exists()) {
        markTestSkipped(
          '设置 QQM_NODE_HOST_CACHE 为已安装通用运行器依赖的测试缓存目录后运行；不使用用户数据。',
        );
        return;
      }
      final root = await Directory.systemTemp.createTemp(
        'qqm-node-native-fixture-',
      );
      final host = Directory(p.join(root.path, 'host'));
      await host.create();
      final dependencyLink = p.join(host.path, 'node_modules');
      final result = await Process.run(Platform.isWindows ? 'node.exe' : 'node', [
        '-e',
        'require("node:fs").symlinkSync(process.argv[1],process.argv[2],process.platform==="win32"?"junction":"dir")',
        p.join(cache, 'node_modules'),
        dependencyLink,
      ]);
      expect(result.exitCode, 0);
      await File(p.join(host.path, '.dependencies-ready')).writeAsString(
        sha256
            .convert(
              await File('assets/node_plugins/package-lock.json').readAsBytes(),
            )
            .toString(),
      );
      final service = NodePluginService(root);
      final storage = MemoryStorage(config: validConfig())
        ..selectChatAccount('fixture-app');
      final manager = TestPluginManager(storage)..nodePackages = service;
      final deliveries = <Map<String, dynamic>>[];
      manager.serviceReady = () => true;
      manager.serviceRequest = (message) async {
        deliveries.add(message);
        return {
          'ok': true,
          'message_id': 'real-fixture-platform-${deliveries.length}',
        };
      };
      try {
        await manager.init();
        final preview = await service.inspectFile(
          File('test/fixtures/node_original/demo.js'),
        );
        final info = await manager.installNodePackage(
          preview['stage_id'].toString(),
        );
        expect(info.isEnabled, false);
        expect(info.manifest['runtime'], 'node');
        expect(info.manifest.containsKey('http'), false);
        await manager.enablePlugin(info.id);
        PluginMessage message(String id) => PluginMessage(
          messageId: id,
          sessionId: 'group',
          senderId: 'user',
          senderName: '测试',
          content: '/原包测试',
          messageType: 0,
          isGroup: true,
          timestamp: DateTime.now(),
        );
        expect(await manager.processMessage(message('first')), isEmpty);
        await until(() => deliveries.length == 1);
        expect(deliveries.single['content'], '原包测试：默认配置 / 1');
        final original = await service.request('/packages/file', {
          'id': info.id,
          'app_id': 'fixture-app',
          'scope': 'source',
          'file': 'apps/main.js',
        });
        await service.request('/packages/file', {
          'id': info.id,
          'app_id': 'fixture-app',
          'scope': 'source',
          'file': 'apps/main.js',
          'content': original['content'].toString().replaceAll(
            '原包测试：',
            '源码修改后：',
          ),
        });
        await manager.reloadNodePackage(info.id);
        expect(await manager.processMessage(message('second')), isEmpty);
        await until(() => deliveries.length == 2);
        expect(deliveries.last['content'], '源码修改后：默认配置 / 2');
        await manager.disablePlugin(info.id);
        await service.pause();
      } finally {
        await service.stopLocal();
        manager.dispose();
        if (await FileSystemEntity.type(dependencyLink, followLinks: false) ==
            FileSystemEntityType.link) {
          await Link(dependencyLink).delete();
        }
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
