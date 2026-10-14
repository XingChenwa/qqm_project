import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
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

  // Initialize plugin manager (built-in plugins registered in code)
  final pluginManager = PluginManager(storageService);
  await pluginManager.init();

  // Initialize bot client
  final botClient = BotClient(storageService);

  // Configure window for desktop
  if (isDesktopPlatform) {
    await windowManager.ensureInitialized();
    final windowOptions = WindowOptions(
      size: const Size(1280, 800),
      minimumSize: const Size(960, 600),
      title: 'QQ 机器人管理器',
      center: true,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storageService),
        ChangeNotifierProvider<PluginManager>.value(value: pluginManager),
        ChangeNotifierProvider<BotClient>.value(value: botClient),
      ],
      child: const QQBotManagerApp(),
    ),
  );
}
