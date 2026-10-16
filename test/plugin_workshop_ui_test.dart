import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/services/plugin_workspace.dart';
import 'package:qq_bot_manager/ui/themes/app_theme.dart';
import 'package:qq_bot_manager/ui/widgets/plugin_import_dialog.dart';
import 'package:qq_bot_manager/ui/widgets/plugin_workshop.dart';

import 'support/fakes.dart';

Future<void> settleFiles(WidgetTester tester) async {
  for (var i = 0; i < 240; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (const bool.fromEnvironment('QQM_CAPTURE_UI') && Platform.isWindows) {
      final bytes = ByteData.sublistView(
        await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes(),
      );
      for (final name in ['Microsoft YaHei', 'monospace']) {
        await (FontLoader(name)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  testWidgets('空工作区可以生成完整插件项目并打开编辑器，不覆盖已有项目', (tester) async {
    final manager = PluginManager(MemoryStorage());
    addTearDown(manager.dispose);
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('qqm-new-project-'),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: PluginWorkshop(manager: manager, root: root),
      ),
    );
    await settleFiles(tester);
    await tester.tap(find.text('新建插件项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await settleFiles(tester);
    final text = tester
        .widget<TextField>(find.byKey(const ValueKey('plugin-file-editor')))
        .controller!
        .text;
    expect(text, contains('my_hello'));
    expect(text, contains('schema_version'));
    expect(
      await tester.runAsync(() => PluginWorkspace(root).files('my_hello')),
      ['plugin.json', 'readme.md'],
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => root.delete(recursive: true));
  });
  for (final width in [320.0, 1280.0]) {
    testWidgets('插件文件管理器 ${width.toInt()} 宽可编辑，切换和关闭保护草稿', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manager = PluginManager(MemoryStorage());
      addTearDown(manager.dispose);
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('qqm-workshop-ui-'),
      );
      final workspace = PluginWorkspace(root!);
      await tester.runAsync(() async {
        await workspace.write(
          'my_plugin',
          'plugin.json',
          PluginWorkspace.rulesManifest(
            id: 'my_plugin',
            name: '测试插件',
            description: '安全编辑测试',
            commands: [
              PluginCommandDraft(value: 'hello', reply: '你好 {{args}}'),
            ],
          ),
        );
        await workspace.write('my_plugin', 'docs/readme.md', '# 开发说明');
      });
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          builder: (_, child) =>
              RepaintBoundary(key: captureKey, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => PluginWorkshop(
                    manager: manager,
                    root: root,
                    initialId: 'my_plugin',
                  ),
                ),
                child: const Text('打开文件管理器'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开文件管理器'));
      await settleFiles(tester);
      expect(find.text('插件文件管理器'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const ValueKey('plugin-file-editor')),
        'draft text',
      );
      if (width < 800) {
        await tester.tap(find.text('文件'));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.byKey(const ValueKey('plugin-explorer')));
      await tester.scrollUntilVisible(
        find.text('docs/readme.md'),
        60,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('plugin-explorer')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('docs/readme.md'));
      await tester.pumpAndSettle();
      expect(find.text('文件尚未保存'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      if (width < 800) {
        await tester.tap(find.text('编辑器'));
        await tester.pumpAndSettle();
      }
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('plugin-file-editor')))
            .controller!
            .text,
        'draft text',
      );
      await tester.tap(find.byTooltip('关闭工作台'));
      await tester.pumpAndSettle();
      expect(find.text('文件尚未保存'), findsOneWidget);
      await tester.tap(find.text('放弃草稿'));
      await tester.pumpAndSettle();
      expect(find.byType(PluginWorkshop), findsNothing);
      await tester.tap(find.text('打开文件管理器'));
      await settleFiles(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('plugin-file-editor')))
            .controller!
            .text,
        contains('schema_version'),
      );
      await tester.runAsync(() async {
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory('build/plugin-previews');
        await folder.create(recursive: true);
        await File(
          '${folder.path}/workshop-${width.toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => root.delete(recursive: true));
    });
  }

  testWidgets('保存冲突阻止安装；有效清单安装仍需权限确认，不静默替换', (tester) async {
    final manager = PluginManager(MemoryStorage());
    addTearDown(manager.dispose);
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('qqm-workshop-consent-'),
    ))!;
    final workspace = PluginWorkspace(root);
    final source = PluginWorkspace.rulesManifest(
      id: 'my_plugin',
      name: '测试',
      description: '测试',
      commands: [PluginCommandDraft(value: 'hello', reply: 'hello')],
    );
    await tester.runAsync(
      () => workspace.write('my_plugin', 'plugin.json', source),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: PluginWorkshop(
          manager: manager,
          root: root,
          initialId: 'my_plugin',
        ),
      ),
    );
    await settleFiles(tester);
    await tester.enterText(
      find.byKey(const ValueKey('plugin-file-editor')),
      source.replaceAll('hello', 'newhello'),
    );
    await tester.runAsync(
      () => workspace.write(
        'my_plugin',
        'plugin.json',
        source.replaceAll('hello', 'otherhello'),
      ),
    );
    await tester.tap(find.text('安装到插件中心'));
    await settleFiles(tester);
    expect(find.byType(PluginImportDialog), findsNothing);
    expect(find.textContaining('文件已被其他窗口修改'), findsOneWidget);
    expect(manager.plugins, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: PluginWorkshop(
          manager: manager,
          root: root,
          initialId: 'my_plugin',
        ),
      ),
    );
    await settleFiles(tester);
    await tester.tap(find.text('安装到插件中心'));
    await settleFiles(tester);
    expect(find.byType(PluginImportDialog), findsOneWidget);
    expect(find.text('检查清单'), findsOneWidget);
    expect(manager.plugins, isEmpty);
    await tester.tap(find.text('检查清单'));
    await tester.pumpAndSettle();
    expect(find.text('我已了解权限及数据用途，允许安装此插件。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认导入'))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => root.delete(recursive: true));
  });
}
