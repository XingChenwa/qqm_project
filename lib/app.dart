import 'utils/platforms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'ui/screens/main_screen.dart';
import 'ui/themes/app_theme.dart';
import 'services/storage_service.dart';
import 'services/theme_preferences.dart';
import 'services/desktop_window_controller.dart';
import 'ui/widgets/desktop_window_frame.dart';
import 'ui/widgets/window_close_dialog.dart';
import 'services/app_update_service.dart';
import 'services/onboarding_preferences.dart';
import 'ui/widgets/update_panel.dart';
import 'ui/widgets/app_dialogs.dart';
import 'ui/screens/onboarding_screen.dart';

class QQBotManagerApp extends StatefulWidget {
  const QQBotManagerApp({super.key});

  @override
  State<QQBotManagerApp> createState() => _QQBotManagerAppState();
}

class _QQBotManagerAppState extends State<QQBotManagerApp> {
  late final ThemePreferences _appearance;
  ThemeMode get _themeMode => _appearance.mode;
  final _navigatorKey = GlobalKey<NavigatorState>();
  DesktopWindowController? _desktopWindow;
  bool _showOnboarding = false;
  bool _openConnection = false;
  @override
  void initState() {
    super.initState();
    _appearance = ThemePreferences(context.read<StorageService>());
    final onboarding = context.read<OnboardingPreferences?>();
    _showOnboarding = onboarding != null && !onboarding.completed;
    WidgetsBinding.instance.addPostFrameCallback((_) => _startUpdates());
  }

  void _startUpdates() {
    if (!mounted || _showOnboarding) return;
    final updates = context.read<AppUpdateService?>();
    if (updates == null || !updates.configured) return;
    updates.start();
  }

  Future<void> _finishOnboarding(bool openConnection) async {
    var saved = true;
    try {
      await context.read<OnboardingPreferences?>()?.complete();
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    setState(() {
      _showOnboarding = false;
      _openConnection = openConnection;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startUpdates();
      final target = _navigatorKey.currentState?.overlay?.context;
      if (!saved && mounted && target != null) {
        AppDialogs.show(target, '已进入工作台，但引导状态未能保存，下次打开可能再次显示。');
      }
    });
  }

  Future<void> toggleTheme() async {
    final dark =
        _themeMode == ThemeMode.dark ||
        _themeMode == ThemeMode.system &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.dark;
    try {
      await _appearance.select(dark ? ThemeMode.light : ThemeMode.dark);
    } catch (_) {
      final target = _navigatorKey.currentState?.overlay?.context;
      if (mounted && target != null && target.mounted) {
        AppDialogs.show(target, '主题未能保存，请重试。', error: true);
      }
    }
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
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ThemePreferences>.value(
      value: _appearance,
      child: ListenableBuilder(
        listenable: _appearance,
        builder: (context, _) => MaterialApp(
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
            Widget content = UpdateNotice(
              enabled: !_showOnboarding,
              child: child!,
              dialogContext: () => _navigatorKey.currentState!.overlay!.context,
            );
            if (usePhoneLayout(context)) {
              content = Theme(
                data: AppTheme.phoneTheme(Theme.of(context)),
                child: content,
              );
            }
            return desktop == null || !desktop.supported
                ? content
                : DesktopWindowFrame(controller: desktop, child: content);
          },
          home: _showOnboarding
              ? OnboardingScreen(onFinished: _finishOnboarding)
              : MainScreen(
                  toggleTheme: toggleTheme,
                  themeMode: _themeMode,
                  openSettingsOnStart: _openConnection,
                ),
        ),
      ),
    );
  }
}
