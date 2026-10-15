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

class QQBotManagerApp extends StatefulWidget {
  const QQBotManagerApp({super.key});

  @override
  State<QQBotManagerApp> createState() => _QQBotManagerAppState();
}

class _QQBotManagerAppState extends State<QQBotManagerApp> {
  ThemeMode _themeMode = ThemeMode.light;
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
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
      _messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: const Text(
            '使用统计默认开启：发送设备名称／型号、系统、软件版本和来源 IP。可在「设置 → 更新」关闭并删除。',
          ),
          duration: const Duration(seconds: 12),
          action: SnackBarAction(
            label: '关闭统计',
            onPressed: () => updates.setUsageConsent(false),
          ),
        ),
      );
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
      scaffoldMessengerKey: _messengerKey,
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
