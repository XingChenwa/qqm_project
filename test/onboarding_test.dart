import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qq_bot_manager/app.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/services/onboarding_preferences.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/onboarding_screen.dart';
import 'package:qq_bot_manager/ui/screens/settings_screen.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';

import 'support/fakes.dart';

Widget onboardingHost(
  MemoryStorage storage,
  BotClient bot,
  PluginManager plugins,
  OnboardingPreferences preferences,
) => MultiProvider(
  providers: [
    Provider<StorageService>.value(value: storage),
    Provider<OnboardingPreferences>.value(value: preferences),
    ChangeNotifierProvider<BotClient>.value(value: bot),
    ChangeNotifierProvider<PluginManager>.value(value: plugins),
  ],
  child: const QQBotManagerApp(),
);

void main() {
  testWidgets('首次引导可直接跳过，重启后不重复，也不生成二维码或连接 QQ', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = OnboardingPreferences(
      await SharedPreferences.getInstance(),
    );
    final storage = MemoryStorage();
    final api = RecordingApi();
    final bot = BotClient(storage, apiService: api);
    final plugins = PluginManager(storage);
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    await tester.pumpWidget(onboardingHost(storage, bot, plugins, preferences));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(MainScreen), findsNothing);
    await tester.tap(find.text('跳过引导'));
    await tester.pumpAndSettle();
    expect(preferences.completed, isTrue);
    expect(find.byType(MainScreen), findsOneWidget);
    expect(api.tokenRequests, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(onboardingHost(storage, bot, plugins, preferences));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.byType(MainScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(1280, 800),
  ]) {
    testWidgets('四步引导在 ${size.width.toInt()} 宽可完成，接入默认打开扫码设置', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final preferences = OnboardingPreferences(
        await SharedPreferences.getInstance(),
      );
      final storage = MemoryStorage();
      final bot = BotClient(storage, apiService: RecordingApi());
      final plugins = PluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await tester.pumpWidget(
        onboardingHost(storage, bot, plugins, preferences),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(find.text('准备好了，开始吧'), findsOneWidget);
      await tester.tap(find.text('开始接入机器人'));
      await tester.pumpAndSettle();
      expect(preferences.completed, isTrue);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('扫码连接（推荐）'), findsOneWidget);
      expect(find.text('手动配置'), findsOneWidget);
      expect(find.text('生成登录二维码'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('引导可回到上一步、任意一步跳过，并支持大字体', (tester) async {
    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: OnboardingScreen(
          onFinished: (open) async {
            expect(open, isFalse);
            finished = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('先接入你的机器人'), findsOneWidget);
    await tester.tap(find.text('跳过引导'));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已完成用户可从关于重新查看，返回不重置首次标记', (tester) async {
    SharedPreferences.setMockInitialValues({'onboarding_completed': true});
    final preferences = OnboardingPreferences(
      await SharedPreferences.getInstance(),
    );
    final storage = MemoryStorage();
    final bot = BotClient(storage);
    final plugins = PluginManager(storage);
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<BotClient>.value(value: bot),
          ChangeNotifierProvider<PluginManager>.value(value: plugins),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关于'));
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重新查看使用引导'));
    await tester.tap(find.text('重新查看使用引导'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    await tester.tap(find.text('返回工作台'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(preferences.completed, isTrue);
  });
}
