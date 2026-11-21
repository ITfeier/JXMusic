import 'package:flutter/material.dart';
import 'core/constants.dart';

/// 构建 JXMusic 主题（iOS26 液态玻璃风格：高光、通透、柔和）
ThemeData buildJXTheme(Color seedColor, {required bool darkMode}) {
  final brightness = darkMode ? Brightness.dark : Brightness.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    surface: darkMode ? JXColors.bgDark : JXColors.bgLight,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor:
        darkMode ? JXColors.bgDark : JXColors.bgLight,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor:
          darkMode ? JXColors.textOnDark : JXColors.textPrimary,
      displayColor:
          darkMode ? JXColors.textOnDark : JXColors.textPrimary,
    ),
    cardTheme: CardThemeData(
      color: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
    ),
    iconTheme: IconThemeData(
      color: darkMode ? JXColors.textOnDark : JXColors.textPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: darkMode ? JXColors.textOnDark : JXColors.textPrimary,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: (darkMode ? JXColors.glassDark : JXColors.glassStrokeLight)
          .withValues(alpha: 0.35),
      thickness: 0.6,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
    ),
    splashFactory: InkSparkle.splashFactory,
    snackBarTheme: SnackBarThemeData(
      // 兜底：未经 jxShowNotice 的裸 SnackBar 也保持悬浮玻璃观感
      // （jxShowNotice 自带完整玻璃胶囊，逐项覆盖这些主题值）
      behavior: SnackBarBehavior.floating,
      backgroundColor: (darkMode ? JXColors.glassDark : JXColors.glassLight)
          .withValues(alpha: 0.95),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color:
              darkMode ? JXColors.glassStrokeDark : JXColors.glassStrokeLight,
        ),
      ),
      contentTextStyle: TextStyle(
        fontSize: 13,
        color: darkMode ? JXColors.textOnDark : JXColors.textPrimary,
      ),
    ),
  );
}
