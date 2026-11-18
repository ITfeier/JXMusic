import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/constants.dart';
import 'providers.dart';
import 'services/avsession_service.dart';
import 'services/mini_mode.dart';
import 'services/tray_service.dart';
import 'ui/mini_player_page.dart';
import 'ui/shell_page.dart';
import 'ui/shortcuts.dart';
import 'theme.dart';

class JXApp extends ConsumerStatefulWidget {
  const JXApp({super.key});

  @override
  ConsumerState<JXApp> createState() => _JXAppState();
}

class _JXAppState extends ConsumerState<JXApp> {
  @override
  void initState() {
    super.initState();
    // 预加载播放器服务，并初始化系统托盘（不支持的平台会直接跳过）
    Future.microtask(() async {
      if (!mounted) return;
      final player = ref.read(playerServiceProvider);
      if (MiniMode.supported) {
        await TrayService.instance.init(player);
      }
      // ohos：系统媒体会话（锁屏/播控中心/耳机线控）+ 后台播放长时任务
      if (AvSessionService.supported) {
        await AvSessionService.instance.init(player);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = ref.watch(darkModeProvider);
    final followSystem = ref.watch(followSystemThemeProvider);
    final seedColor = ref.watch(themeColorProvider);
    final miniMode = ref.watch(miniModeProvider);

    return MaterialApp(
      title: JXConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: buildJXTheme(seedColor, darkMode: false),
      darkTheme: buildJXTheme(seedColor, darkMode: true),
      // 跟随系统时交给 MaterialApp 的 ThemeMode.system（自动随系统切换）；
      // 手动模式按深色开关取 dark/light。
      themeMode: followSystem
          ? ThemeMode.system
          : (dark ? ThemeMode.dark : ThemeMode.light),
      home: JXKeyboardShortcuts(
        child: miniMode ? const MiniPlayerPage() : const ShellPage(),
      ),
      builder: (context, child) {
        // 全局背景渐变 + 液态玻璃氛围
        return AnimatedBuilder(
          animation: Listenable.merge(const []),
          builder: (context, _) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              // 系统状态栏/导航栏样式统一在这里声明一处（G3）：栏本身透明，
              // 图标颜色按主题亮度取反（浅色主题深色图标 / 深色主题浅色图标），
              // 避免浅色主题下状态栏图标看不清。用 AnnotatedRegion 而非
              // SystemChrome.setSystemUIOverlayStyle，页面切换时由框架自动还原。
              // Windows 桌面没有系统状态栏，AnnotatedRegion 无副作用（G4）。
              value: jxSystemUiOverlayStyle(dark: isDark),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDark
                        ? const [
                            Color(0xFF0B0E16),
                            Color(0xFF121826),
                            Color(0xFF0F1320),
                          ]
                        : const [
                            Color(0xFFE8EEF8),
                            Color(0xFFF2F4FA),
                            Color(0xFFE3EAF7),
                          ],
                  ),
                ),
                child: child,
              ),
            );
          },
        );
      },
    );
  }
}

/// 系统栏（状态栏 + 导航栏）样式：透明背景 + 按主题亮度切换图标深浅。
///
/// Android 15/16（targetSdk=36）强制 edge-to-edge 后，系统栏颜色由 App 内容决定，
/// 这里只声明「透明 + 图标亮度」，实际内容由 lib/ui 的安全区容器避让。
SystemUiOverlayStyle jxSystemUiOverlayStyle({required bool dark}) {
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    // iOS 语义：状态栏背景亮度，与图标亮度相反。
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );
}
