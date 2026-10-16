import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/app_update_service.dart';
import 'services/update_preferences.dart';
import 'services/onboarding_preferences.dart';
import 'services/desktop_window_controller.dart';
import 'app.dart';
import 'models/message.dart';
import 'models/plugin.dart';
import 'models/config.dart';
import 'services/storage_service.dart';
import 'core/bot_client.dart';
import 'core/plugin_manager.dart';
import 'utils/platforms.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive for local storage
  await Hive.initFlutter();
  Hive.registerAdapter(MessageModelAdapter());
  Hive.registerAdapter(ChatSessionAdapter());
  Hive.registerAdapter(EmojiItemAdapter());
  Hive.registerAdapter(PluginConfigAdapter());
  Hive.registerAdapter(BotConfigAdapter());

  // Initialize storage service
  final storageService = StorageService();
  await storageService.init();

  // 从 plugins/ 清单加载内置实现，并恢复已安装的 JSON/YAML/HTTP 插件。
  final pluginManager = PluginManager(storageService);
  await pluginManager.init();

  // Initialize bot client
  final botClient = BotClient(storageService);
  final preferences = await SharedPreferences.getInstance();
  final updates = AppUpdateService(UpdatePreferences(preferences));
  final onboarding = OnboardingPreferences(preferences);

  DesktopWindowController? desktopWindow;
  if (isDesktopPlatform) {
    desktopWindow = DesktopWindowController(
      storageService,
      beforeExit: () async {
        await storageService.flush();
        updates.dispose();
        botClient.dispose();
        pluginManager.dispose();
      },
    );
    await desktopWindow.initialize();
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storageService),
        Provider<OnboardingPreferences>.value(value: onboarding),
        ChangeNotifierProvider<PluginManager>.value(value: pluginManager),
        ChangeNotifierProvider<BotClient>.value(value: botClient),
        ChangeNotifierProvider<AppUpdateService>.value(value: updates),
        if (desktopWindow != null)
          ChangeNotifierProvider<DesktopWindowController>.value(
            value: desktopWindow,
          ),
      ],
      child: const QQBotManagerApp(),
    ),
  );
}
