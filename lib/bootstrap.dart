import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/app_update_service.dart';
import 'services/update_preferences.dart';
import 'utils/constants.dart';
import 'services/onboarding_preferences.dart';
import 'services/desktop_window_controller.dart';
import 'services/auxiliary_windows.dart';
import 'services/mobile_connection.dart';
import 'app.dart';
import 'models/message.dart';
import 'models/plugin.dart';
import 'models/config.dart';
import 'services/storage_service.dart';
import 'core/bot_client.dart';
import 'core/plugin_manager.dart';
import 'utils/platforms.dart';
import 'agent/controller.dart';
import 'core/official_workspace_link.dart';
import 'agent/pending_imports.dart';
import 'services/video_thumbnail_service.dart';
import 'services/video_frame_service.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'agent/store.dart';
import 'services/data_migration_service.dart';
import 'core/plugin_service_dispatcher.dart';
import 'services/node_plugin_service.dart';

Future<Widget> initializeApplication(
  void Function(String) report, {
  Future<void> Function()? prepareStorage,
}) async {
  // Initialize Hive for local storage
  report('准备本地存储');
  await (prepareStorage?.call() ?? Hive.initFlutter());
  _registerAdapter<MessageModel>(MessageModelAdapter());
  _registerAdapter<ChatSession>(ChatSessionAdapter());
  _registerAdapter<EmojiItem>(EmojiItemAdapter());
  _registerAdapter<PluginInfo>(PluginConfigAdapter());
  _registerAdapter<BotConfig>(BotConfigAdapter());

  // Initialize storage service
  final storageService = StorageService();
  report('读取本地配置和聊天记录');
  await storageService.init(report: report);

  report('检查完整数据迁移');
  final agentStore = AgentStore();
  final migration = DataMigrationService(
    storage: storageService,
    agent: agentStore,
    dataRoot: Directory(p.dirname(storageService.dataPath!)),
    workspaceRootResolver: () async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'plugin_workspace'),
    ),
  );
  migration.startupNotice = await migration.applyPendingRestore();
  if (migration.startupNotice != null) {
    await storageService.init(report: report);
  }

  // 从 plugins/ 清单加载内置实现，并恢复已安装的 JSON/YAML/HTTP 插件。
  final nodePackages = NodePluginService(
    Directory(p.join(p.dirname(storageService.dataPath!), 'node_plugins')),
  );
  final pluginManager = PluginManager(
    storageService,
    nodePackages: nodePackages,
  );
  report('加载内置插件');
  await pluginManager.init();

  // Initialize bot client
  report('准备机器人工作台');
  final botClient = BotClient(storageService);
  PluginServiceDispatcher(botClient, storageService).bind(pluginManager);
  final preferences = await SharedPreferences.getInstance();
  final updates = AppUpdateService(
    UpdatePreferences(
      preferences,
      channel:
          (AppConstants.releaseChannel == 'beta' ||
              (AppConstants.releaseChannel.isEmpty &&
                  AppConstants.appVersion.contains('-')))
          ? UpdateChannel.beta
          : UpdateChannel.stable,
    ),
  );
  final onboarding = OnboardingPreferences(preferences);
  // The Agent database and sockets are lazy: opening the official workspace
  // never initializes or connects a OneBot account.
  final agent = AgentController(
    store: agentStore,
    pendingImportsDirectory: defaultAgentPendingImportsDirectory(),
    videoThumbnail: VideoThumbnailService.shared.load,
    videoFrameReader: VideoFrameService.shared.extract,
  );
  linkOfficialWorkspaces(botClient, agent, storageService);
  migration.beforeRestore = () async {
    botClient.disconnect();
    await Future.wait([
      botClient.pauseForMigration(),
      agent.pauseForMigration(),
      pluginManager.pauseForMigration(),
    ]);
    await nodePackages.pause();
  };
  migration.beforeSnapshot = () async {
    await nodePackages.pause();
    try {
      await agent.pauseExternalSources();
    } catch (_) {
      nodePackages.resume();
      rethrow;
    }
  };
  migration.afterSnapshot = () async {
    agent.resumeExternalSources();
    nodePackages.resume();
  };
  migration.onStageFailure = () async {
    agent.migrationPaused = false;
    agent.resumeExternalSources();
    nodePackages.resume();
    await pluginManager.init();
  };

  DesktopWindowController? desktopWindow;
  if (isDesktopPlatform) {
    report('准备桌面窗口');
    desktopWindow = DesktopWindowController(
      storageService,
      beforeExit: () async {
        await agent.shutdown();
        botClient.disconnect();
        await botClient.groups.flush();
        await storageService.flush();
        updates.dispose();
        botClient.dispose();
        pluginManager.dispose();
      },
    );
    await desktopWindow.initialize();
  }

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<DataMigrationService>.value(value: migration),
      ChangeNotifierProvider<AgentController>(create: (_) => agent),
      Provider<StorageService>.value(value: storageService),
      Provider<OnboardingPreferences>.value(value: onboarding),
      Provider<AuxiliaryWindows>(create: (_) => AuxiliaryWindows()),
      ChangeNotifierProvider<PluginManager>.value(value: pluginManager),
      ChangeNotifierProvider<BotClient>.value(value: botClient),
      ChangeNotifierProvider<MobileConnection>(
        create: (_) =>
            MobileConnection(bot: botClient, storage: storageService)..start(),
        lazy: false,
      ),
      ChangeNotifierProvider<AppUpdateService>.value(value: updates),
      if (desktopWindow != null)
        ChangeNotifierProvider<DesktopWindowController>.value(
          value: desktopWindow,
        ),
    ],
    child: const QQBotManagerApp(),
  );
}

void _registerAdapter<T>(TypeAdapter<T> adapter) {
  if (!Hive.isAdapterRegistered(adapter.typeId)) {
    Hive.registerAdapter<T>(adapter);
  }
}
