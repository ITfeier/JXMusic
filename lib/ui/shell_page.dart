import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/playback.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'search_page.dart';
import 'local_page.dart';
import 'settings_page.dart';
import 'player/player_bar.dart';
import 'layout.dart';

/// 主界面壳（双端独立布局）：
/// - 桌面版：左侧固定玻璃导航栏 + 顶部内容工具条 + 内容区 + 底部迷你播放条
/// - 手机版：内容区 + 迷你播放条 + 底部玻璃 Tab（首页/搜索/音乐库/本地/设置）
class ShellPage extends ConsumerWidget {
  const ShellPage({super.key});

  static const _pageTitles = ['首页', '搜索', '音乐库', '本地音乐', '设置'];
  static const _pageCrumbs = [
    '/ 推荐',
    '/ 聚合搜索',
    '/ 收藏 · 历史 · 歌单',
    '/ 本地曲库',
    '/ 偏好',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(navIndexProvider);
    final desktop = isDesktopLayout(context);

    // 队列懒解密失败提示（评审 R-11）：自动下一首/播放全部遇到无法解密的文件时，
    // PlayerService.lastResolutionError 会给出具体中文原因，这里用 SnackBar 提示一次。
    ref.listen<String?>(
      playerServiceProvider.select((p) => p.lastResolutionError),
      (previous, next) {
        if (next == null || next.isEmpty || next == previous) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(next)));
          ref.read(playerServiceProvider).clearResolutionError();
        });
      },
    );

    // 本地曲目播放：加密格式由 PlayerService 的 resolver 解密（点击时页面已带
    // 进度预解密并回填元数据）；这里统一走 resolveAndPlay，队列保留源文件路径。
    void playLocalQueue(List<Song> queue, int index) {
      if (index < 0 || index >= queue.length) return;
      resolveAndPlay(ref, queue[index], queue: queue);
    }

    final pages = <Widget>[
      const HomePage(),
      const SearchPage(),
      const LibraryPage(),
      LocalPage(
        musicService: ref.read(localMusicServiceProvider),
        formatService: ref.read(localFormatServiceProvider),
        pathsStore: ref.read(localPathsStoreProvider),
        playQueue: playLocalQueue,
      ),
      const SettingsPage(),
    ];

    final navItems = [
      (Icons.home_rounded, '首页'),
      (Icons.search_rounded, '搜索'),
      (Icons.library_music_rounded, '音乐库'),
      (Icons.folder_rounded, '本地'),
      (Icons.settings_rounded, '设置'),
    ];

    void switchTab(int i) => ref.read(navIndexProvider.notifier).state = i;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: desktop
          ? Row(
              children: [
                _DesktopSidebar(
                  index: index,
                  navItems: navItems,
                  onTap: switchTab,
                ),
                Expanded(
                  child: Column(
                    children: [
                      _DesktopTopBar(
                        title: _pageTitles[index],
                        crumb: _pageCrumbs[index],
                        onSearch: () => switchTab(1),
                        onAvatar: () => switchTab(4),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 20, 0),
                          child: IndexedStack(index: index, children: pages),
                        ),
                      ),
                      const PlayerBar(),
                    ],
                  ),
                ),
              ],
            )
          : MobileShellBody(
              pages: pages,
              index: index,
              navItems: navItems,
              onTap: switchTab,
            ),
    );
  }
}

/// 手机端壳层内容区：安全区内容区（五个 tab 页）+ 迷你播放条 + 底部玻璃 Tab。
///
/// 单独公开的唯一目的是让 widget 测试可以直接验证「系统安全区只在壳层避让
/// 一次」的接线，而不必拉起 `PlayerService`（media_kit Player）与 Hive 存档
/// （测试可传 [playerBar] 换掉迷你播放条）。
class MobileShellBody extends StatelessWidget {
  const MobileShellBody({
    super.key,
    required this.pages,
    required this.index,
    required this.navItems,
    required this.onTap,
    this.playerBar = const PlayerBar(),
  });

  /// 五个 tab 页（顺序必须与 [navItems] 一致）。
  final List<Widget> pages;
  final int index;
  final List<(IconData, String)> navItems;
  final void Function(int) onTap;

  /// 底部迷你播放条；默认 [PlayerBar]，widget 测试可注入空壳避免拉起播放器。
  final Widget playerBar;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          // 顶部状态栏/刘海/挖孔与横屏左右手势区只在这里避让一次；
          // 页面自身不再各自处理（见 MobilePageSafeArea 的注释）。
          child: MobilePageSafeArea(
            child: IndexedStack(index: index, children: pages),
          ),
        ),
        playerBar,
        _MobileTabBar(index: index, navItems: navItems, onTap: onTap),
      ],
    );
  }
}

/// 桌面左侧固定玻璃导航栏（设计稿：92px 宽、圆角 26）
class _DesktopSidebar extends StatelessWidget {
  final int index;
  final List<(IconData, String)> navItems;
  final void Function(int) onTap;

  const _DesktopSidebar({
    required this.index,
    required this.navItems,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 92,
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: isDark ? JXColors.glassStrokeDark : JXColors.glassStrokeLight,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilterWrapper.blur(18),
          child: Container(
            color: (isDark ? JXColors.glassDark : JXColors.glassLight)
                .withValues(alpha: 0.7),
            child: Column(
              children: [
                const SizedBox(height: 22),
                // Logo
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [JXColors.primary, JXColors.accentCyan],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: JXColors.primary.withValues(alpha: 0.4),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.graphic_eq_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  JXConstants.appName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isDark ? JXColors.textOnDark : JXColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 26),
                Expanded(
                  child: ListView.builder(
                    itemCount: navItems.length,
                    itemBuilder: (context, i) {
                      final selected = index == i;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 12,
                        ),
                        child: GestureDetector(
                          onTap: () => onTap(i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            height: 56,
                            decoration: BoxDecoration(
                              gradient: selected
                                  ? LinearGradient(
                                      colors: [
                                        JXColors.primary.withValues(alpha: 0.9),
                                        JXColors.primary.withValues(alpha: 0.6),
                                      ],
                                    )
                                  : null,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  navItems[i].$1,
                                  color: selected
                                      ? Colors.white
                                      : isDark
                                      ? JXColors.textOnDarkSecondary
                                      : JXColors.textSecondary,
                                  size: 22,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  navItems[i].$2,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: selected
                                        ? Colors.white
                                        : isDark
                                        ? JXColors.textOnDarkSecondary
                                        : JXColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 桌面顶部内容工具条（设计稿 topbar：标题 + 面包屑 + 搜索框 + 头像）
class _DesktopTopBar extends StatelessWidget {
  final String title;
  final String crumb;
  final VoidCallback onSearch;
  final VoidCallback onAvatar;

  const _DesktopTopBar({
    required this.title,
    required this.crumb,
    required this.onSearch,
    required this.onAvatar,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub = isDark
        ? JXColors.textOnDarkSecondary
        : JXColors.textSecondary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 20, 6),
      child: Row(
        children: [
          // 标题 + 面包屑
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  crumb,
                  style: TextStyle(fontSize: 11, color: textSub),
                ),
              ),
            ],
          ),
          const Spacer(),
          // 搜索框
          GestureDetector(
            onTap: onSearch,
            child: Container(
              width: 220,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: (isDark ? JXColors.glassDark : JXColors.glassLight)
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isDark
                      ? JXColors.glassStrokeDark
                      : JXColors.glassStrokeLight,
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 19,
                    color: JXColors.primary,
                  ),
                  const SizedBox(width: 8),
                  // 文案宽度随可用宽度收缩：真实中文字体下原本就放得下，
                  // 但等宽/异体字体或系统字体放大时固定宽度 220dp 会横向溢出
                  // （QA 验收用例在测试字体下暴露 8.5px overflow）。加省略号只
                  // 在放不下时生效，正常桌面渲染与改动前一致。
                  Flexible(
                    child: Text(
                      '搜索歌曲 / 歌手 / 专辑',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: textSub),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),
          // 头像
          GestureDetector(
            onTap: onAvatar,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [JXColors.accentPink, JXColors.accent],
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: JXColors.accent.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(
                Icons.person_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 手机底部玻璃 Tab（设计稿：首页/搜索/本地/设置）
class _MobileTabBar extends StatelessWidget {
  final int index;
  final List<(IconData, String)> navItems;
  final void Function(int) onTap;

  const _MobileTabBar({
    required this.index,
    required this.navItems,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark
                  ? JXColors.glassStrokeDark
                  : JXColors.glassStrokeLight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilterWrapper.blur(18),
              child: Container(
                height: 60,
                color: (isDark ? JXColors.glassDark : JXColors.glassLight)
                    .withValues(alpha: 0.72),
                child: Row(
                  children: [
                    for (var i = 0; i < navItems.length; i++)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onTap(i),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: index == i
                                      ? JXColors.primary.withValues(alpha: 0.16)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  navItems[i].$1,
                                  size: 22,
                                  color: index == i
                                      ? JXColors.primary
                                      : isDark
                                      ? JXColors.textOnDarkSecondary
                                      : JXColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                navItems[i].$2,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: index == i
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color: index == i
                                      ? JXColors.primary
                                      : isDark
                                      ? JXColors.textOnDarkSecondary
                                      : JXColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// BackdropFilter 别名（避免与 dart:ui 冲突的辅助封装）
class ImageFilterWrapper {
  static ImageFilter blur(double sigma) =>
      ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
}
