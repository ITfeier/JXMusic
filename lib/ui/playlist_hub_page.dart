import 'package:flutter/material.dart';

import '../core/constants.dart';
import 'glass.dart';
import 'playlist_list_page.dart';
import 'playlist_row.dart';

/// 「全部歌单 · 三平台」聚合页。
///
/// 首页聚合推荐歌单区块右上「更多」进入：顶部平台 pill（QQ音乐 / 网易云 /
/// 酷狗）切换，内容区 [IndexedStack] 同时持有三个平台的 [PlaylistListPage]
/// （各自独立分页加载，切换不丢状态），内嵌时隐藏其返回/刷新按钮。
///
/// 头部「更新」按钮：一次点击同时刷新全部三平台子页（各自随机起始页、
/// 并行请求），满足「所有歌单同步更新、同时更新、随机更新」。
class PlaylistHubPage extends StatefulWidget {
  final int initialPlatform;

  const PlaylistHubPage({super.key, this.initialPlatform = JXPlatform.qq});

  @override
  State<PlaylistHubPage> createState() => _PlaylistHubPageState();
}

class _PlaylistHubPageState extends State<PlaylistHubPage> {
  static const List<int> _platforms = [
    JXPlatform.qq,
    JXPlatform.netease,
    JXPlatform.kugou,
  ];

  late int _platform = _platforms.contains(widget.initialPlatform)
      ? widget.initialPlatform
      : JXPlatform.qq;

  /// 各平台子页 key：头部「更新」按钮一次性触发全部子页刷新
  final Map<int, GlobalKey<PlaylistListPageState>> _pageKeys = {
    for (final p in _platforms) p: GlobalKey<PlaylistListPageState>(),
  };

  /// 「更新」：同时刷新全部三平台子页（各回顶 + 重新随机起始页，并行请求）。
  void _refreshAll() {
    for (final key in _pageKeys.values) {
      key.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [const Color(0xFF151B29), const Color(0xFF0B0E16)]
                : [const Color(0xFFE9EFF9), const Color(0xFFDDE6F4)],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    GlassIconButton(
                      icon: Icons.arrow_back_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '全部歌单 · 三平台',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: textColor),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GlassIconButton(
                      icon: Icons.refresh_rounded,
                      size: 36,
                      onPressed: _refreshAll,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Row(
                  children: [
                    for (var i = 0; i < _platforms.length; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: i > 0 ? 10 : 0),
                          child: _buildPill(
                            _platforms[i],
                            isDark,
                            textColor,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: _platforms.indexOf(_platform),
                  children: [
                    for (final p in _platforms)
                      PlaylistListPage(
                          key: _pageKeys[p], platform: p, showBack: false),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 平台切换 pill：选中填平台色，未选中走液态玻璃表面
  Widget _buildPill(int platform, bool isDark, Color textColor) {
    final selected = platform == _platform;
    return GestureDetector(
      onTap: () => setState(() => _platform = platform),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? JXPlatform.color(platform)
              : (isDark ? JXColors.glassDark : JXColors.glassLight)
                  .withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : isDark
                    ? JXColors.glassStrokeDark
                    : JXColors.glassStrokeLight,
          ),
        ),
        child: Text(
          JXPlaylistCard.platformShort(platform),
          maxLines: 1,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : textColor,
          ),
        ),
      ),
    );
  }
}
