import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'ui/screens/main_screen.dart';
import 'ui/themes/app_theme.dart';
import 'services/storage_service.dart';
import 'services/desktop_window_controller.dart';
import 'ui/widgets/desktop_window_frame.dart';
import 'ui/widgets/window_close_dialog.dart';
import 'services/app_update_service.dart';
import 'ui/widgets/update_panel.dart';
import 'ui/widgets/app_dialogs.dart';

class QQBotManagerApp extends StatefulWidget {
  const QQBotManagerApp({super.key});

  @override
  State<QQBotManagerApp> createState() => _QQBotManagerAppState();
}

class _QQBotManagerAppState extends State<QQBotManagerApp> {
  ThemeMode _themeMode = ThemeMode.light;
  final _navigatorKey = GlobalKey<NavigatorState>();
  DesktopWindowController? _desktopWindow;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTheme());
    WidgetsBinding.instance.addPostFrameCallback((_) => _startUpdates());
  }

  Future<void> _startUpdates() async {
    if (!mounted) return;
    final updates = context.read<AppUpdateService?>();
    if (updates == null || !updates.configured) return;
    if (updates.preferences.usageConsent &&
        !updates.preferences.usageNoticeSeen) {
      final target = _navigatorKey.currentState?.overlay?.context;
      if (target == null) return;
      final enabled = await AppDialogs.present<bool>(
        target,
        key: 'usage-notice',
        barrierDismissible: false,
        builder: (dialog) => AlertDialog(
          title: const Text('隐私与使用统计'),
          content: const SingleChildScrollView(
            child: Text(
              '使用统计默认开启，用于了解设备活跃与版本分布。会发送随机安装 ID、设备名称／型号、系统、架构和软件版本，服务器记录来源 IP；不读取机器人密钥或聊天。\n\n可随时在「设置 → 更新 → 隐私与使用统计」关闭并删除记录，不影响软件更新。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('关闭统计'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      if (enabled == false) await updates.setUsageConsent(false);
      await updates.preferences.markUsageNoticeSeen();
    }
    if (mounted) updates.start();
  }

  void _loadTheme() {
    final storage = context.read<StorageService>();
    final isDark = storage.getThemeMode();
    if (mounted) {
      setState(() {
        _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
      });
    }
  }

  void toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.light
          ? ThemeMode.dark
          : ThemeMode.light;
    });
    context.read<StorageService>().setThemeMode(_themeMode == ThemeMode.dark);
  }

  Future<DesktopCloseDecision?> _confirmWindowClose() async {
    final dialogContext = _navigatorKey.currentContext;
    if (!mounted || dialogContext == null) return null;
    return showDialog<DesktopCloseDecision>(
      context: dialogContext,
      builder: (_) => const WindowCloseDialog(),
    );
  }

  @override
  void dispose() {
    _desktopWindow?.confirmClose = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      title: 'QQ 机器人管理器',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      builder: (context, child) {
        final desktop = context.watch<DesktopWindowController?>();
        if (!identical(desktop, _desktopWindow)) {
          _desktopWindow?.confirmClose = null;
          _desktopWindow = desktop;
          desktop?.confirmClose = _confirmWindowClose;
        }
        final content = UpdateNotice(
          child: child!,
          dialogContext: () => _navigatorKey.currentState!.overlay!.context,
        );
        return desktop == null || !desktop.supported
            ? content
            : DesktopWindowFrame(controller: desktop, child: content);
      },
      home: MainScreen(toggleTheme: toggleTheme, themeMode: _themeMode),
    );
  }
}
