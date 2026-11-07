import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/constants.dart';
import 'providers.dart';
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = ref.watch(darkModeProvider);
    final seedColor = ref.watch(themeColorProvider);
    final miniMode = ref.watch(miniModeProvider);

    return MaterialApp(
      title: JXConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: buildJXTheme(seedColor, darkMode: false),
      darkTheme: buildJXTheme(seedColor, darkMode: true),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: JXKeyboardShortcuts(
        child: miniMode ? const MiniPlayerPage() : const ShellPage(),
      ),
      builder: (context, child) {
        // 全局背景渐变 + 液态玻璃氛围
        return AnimatedBuilder(
          animation: Listenable.merge(const []),
          builder: (context, _) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            return Container(
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
            );
          },
        );
      },
    );
  }
}
