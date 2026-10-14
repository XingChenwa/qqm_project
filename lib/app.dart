import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'ui/screens/main_screen.dart';
import 'ui/themes/app_theme.dart';
import 'services/storage_service.dart';

class QQBotManagerApp extends StatefulWidget {
  const QQBotManagerApp({super.key});

  @override
  State<QQBotManagerApp> createState() => _QQBotManagerAppState();
}

class _QQBotManagerAppState extends State<QQBotManagerApp> {
  ThemeMode _themeMode = ThemeMode.light;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTheme());
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      title: 'QQ 机器人管理器',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      home: MainScreen(toggleTheme: toggleTheme, themeMode: _themeMode),
    );
  }
}
