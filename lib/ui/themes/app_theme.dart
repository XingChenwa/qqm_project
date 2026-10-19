import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

class AppTheme {
  static const Color qqBlue = Color(0xFF3268F4);
  static const Color qqGreen = Color(0xFF14B86A);
  static const Color qqRed = Color(0xFFE5484D);
  static const Color amber = Color(0xFFD97706);
  static const Color ink = Color(0xFF172033);
  static const Color muted = Color(0xFF667085);

  static const Color lightBg = Color(0xFFF3F6FC);
  static const Color lightPanel = Color(0xFFFFFFFF);
  static const Color lightSidebar = Color(0xFFEBF1FC);
  static const Color lightDivider = Color(0xFFE7ECF5);

  static const Color darkBg = Color(0xFF0F141B);
  static const Color darkPanel = Color(0xFF171D26);
  static const Color darkSidebar = Color(0xFF131922);
  static const Color darkDivider = Color(0xFF263140);

  static ThemeData phoneTheme(ThemeData base) {
    final dark = base.brightness == Brightness.dark;
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: base.dividerColor),
    );
    return base.copyWith(
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: dark ? darkBg : const Color(0xFFF5F7FB),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(
          borderSide: const BorderSide(color: qqBlue, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 46),
          side: BorderSide(color: base.dividerColor),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        height: 70,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  static ThemeData get lightTheme => _buildTheme(
    brightness: Brightness.light,
    background: lightBg,
    panel: lightPanel,
    sidebar: lightSidebar,
    divider: lightDivider,
    onSurface: ink,
  );

  static ThemeData get darkTheme => _buildTheme(
    brightness: Brightness.dark,
    background: darkBg,
    panel: darkPanel,
    sidebar: darkSidebar,
    divider: darkDivider,
    onSurface: const Color(0xFFE9EEF6),
  );

  static ThemeData _buildTheme({
    required Brightness brightness,
    required Color background,
    required Color panel,
    required Color sidebar,
    required Color divider,
    required Color onSurface,
  }) {
    final isDark = brightness == Brightness.dark;
    final fontFamily = switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.linux => 'Microsoft YaHei',
      _ => null,
    };
    final scheme = ColorScheme.fromSeed(
      seedColor: qqBlue,
      brightness: brightness,
      primary: qqBlue,
      secondary: qqGreen,
      surface: panel,
      error: qqRed,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      primaryColor: qqBlue,
      scaffoldBackgroundColor: background,
      cardColor: panel,
      dividerColor: divider,
      colorScheme: scheme.copyWith(
        surface: panel,
        onSurface: onSurface,
        secondary: qqGreen,
        error: qqRed,
      ),
      fontFamily: fontFamily,
      fontFamilyFallback: const [
        'PingFang SC',
        'Noto Sans CJK SC',
        'Microsoft YaHei',
      ],
      visualDensity: VisualDensity.standard,
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: panel,
        indicatorColor: qqBlue.withValues(alpha: .1),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor: panel,
        foregroundColor: onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily:
              fontFamily ??
              (defaultTargetPlatform == TargetPlatform.iOS
                  ? 'CupertinoSystemDisplay'
                  : 'Roboto'),
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: panel,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: divider),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF111821) : Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 13,
          vertical: 11,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: qqBlue, width: 1.5),
        ),
        hintStyle: TextStyle(
          color: isDark ? const Color(0xFF7D8898) : muted,
          fontSize: 13,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: qqBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: qqBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: qqBlue,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: isDark
              ? const Color(0xFFD6DEEA)
              : const Color(0xFF344054),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return qqBlue;
          return isDark ? const Color(0xFF9AA4B2) : const Color(0xFFFFFFFF);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return qqBlue.withValues(alpha: 0.35);
          }
          return isDark ? const Color(0xFF313B49) : const Color(0xFFD9E0EA);
        }),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: qqBlue,
        unselectedLabelColor: isDark ? const Color(0xFF9AA4B2) : muted,
        indicatorColor: qqBlue,
        indicatorSize: TabBarIndicatorSize.label,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF263140) : const Color(0xFF172033),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}
