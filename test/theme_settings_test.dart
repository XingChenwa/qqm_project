import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/app.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/services/theme_preferences.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';
import 'package:qq_bot_manager/ui/screens/settings_screen.dart';
import 'support/fakes.dart';

void main() {
  for (final width in [320.0, 1100.0]) {
    testWidgets('设置内切换三种主题并持久保存：$width', (tester) async {
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      debugDefaultTargetPlatformOverride = width < 600
          ? TargetPlatform.android
          : TargetPlatform.windows;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final storage = MemoryStorage();
      final bot = BotClient(storage, apiService: RecordingApi());
      final plugins = TestPluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storage),
            ChangeNotifierProvider<BotClient>.value(value: bot),
            ChangeNotifierProvider<PluginManager>.value(value: plugins),
          ],
          child: const QQBotManagerApp(),
        ),
      );
      await tester.pumpAndSettle();
      final root = tester.element(find.byType(MainScreen));
      Navigator.of(
        root,
      ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
      await tester.pumpAndSettle();
      final settings = tester.element(find.byType(SettingsScreen));
      expect(settings.read<ThemePreferences>().mode, ThemeMode.system);
      for (final mode in [ThemeMode.dark, ThemeMode.light, ThemeMode.system]) {
        final tile = find.byKey(ValueKey('theme-${mode.name}'));
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(settings.read<ThemePreferences>().mode, mode);
        expect(storage.getAppearance(), mode.name);
        if (mode != ThemeMode.system) {
          expect(
            Theme.of(settings).brightness,
            mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
          );
        }
      }
      final restored = ThemePreferences(storage);
      expect(restored.mode, ThemeMode.system);
      restored.dispose();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
