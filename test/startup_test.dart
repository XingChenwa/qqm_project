import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qq_bot_manager/app.dart';
import 'package:qq_bot_manager/bootstrap.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/services/app_update_service.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';
import 'package:qq_bot_manager/ui/screens/onboarding_screen.dart';
import 'package:qq_bot_manager/ui/widgets/startup_gate.dart';

void main() {
  testWidgets('首屏不等待插件初始化，成功后进入应用', (tester) async {
    final result = Completer<Widget>();
    await tester.pumpWidget(
      StartupGate(
        initialize: (report) {
          report('读取本地数据');
          return result.future;
        },
      ),
    );
    await tester.pump();
    expect(find.text('QQ机器人管理器'), findsOneWidget);
    expect(find.text('读取本地数据'), findsOneWidget);
    result.complete(const MaterialApp(home: Text('工作台已就绪')));
    await tester.pumpAndSettle();
    expect(find.text('工作台已就绪'), findsOneWidget);
  });
  testWidgets('初始化异常显示可见诊断，但不展示异常携带的密钥', (tester) async {
    await tester.pumpWidget(
      StartupGate(
        initialize: (report) async {
          report('读取本地配置');
          throw const FormatException('clientSecret: MUST-NOT-APPEAR');
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('启动未完成'), findsOneWidget);
    expect(find.text('复制诊断信息'), findsOneWidget);
    expect(find.textContaining('MUST-NOT-APPEAR'), findsNothing);
    expect(find.textContaining('阶段：读取本地配置'), findsOneWidget);
  });
  testWidgets('初始化超时不会无限白屏或在超时后悄悄进入应用', (tester) async {
    final result = Completer<Widget>();
    await tester.pumpWidget(
      StartupGate(
        timeout: const Duration(seconds: 2),
        initialize: (_) => result.future,
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('启动未完成'), findsOneWidget);
    result.complete(const Text('不应进入'));
    await tester.pump();
    expect(find.text('不应进入'), findsNothing);
  });
  testWidgets('Android 首装真实初始化：Hive、七个插件、引导及跳过后的会话页', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('qqm-startup-test-'),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });
    final stages = <String>[];
    final app = await tester.runAsync(
      () => initializeApplication(
        stages.add,
        prepareStorage: () async {
          Hive.init(directory.path);
        },
      ),
    );
    expect(stages, contains('加载内置插件'));
    await tester.pumpWidget(StartupGate(initialize: (_) async => app!));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    final context = tester.element(find.byType(QQBotManagerApp));
    final bot = context.read<BotClient>(),
        plugins = context.read<PluginManager>(),
        updates = context.read<AppUpdateService>();
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    addTearDown(updates.dispose);
    expect(plugins.plugins.length, 7);
    expect(plugins.enabledCount, 0);
    await tester.tap(find.text('跳过引导'));
    await tester.pumpAndSettle();
    expect(find.byType(MainScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
