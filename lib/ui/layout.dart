import 'package:flutter/material.dart';
import '../core/constants.dart';
import 'cover.dart';

/// ===== 响应式布局工具（双端设计稿共用） =====

/// 桌面布局判定：窗口/屏幕宽度 >= 840 视为桌面（Windows 基准 1280，最小 960）
bool isDesktopLayout(BuildContext context) {
  return MediaQuery.of(context).size.width >= 840;
}

/// 播放时长格式化：秒 -> mm:ss
String jxFormatDuration(int seconds) {
  if (seconds <= 0) return '--:--';
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 歌单封面渐变占位（仿设计稿 c1~c6 多彩渐变）
List<Color> jxAlbumGradient(int index) {
  const palettes = <List<Color>>[
    [Color(0xFF3D5FBF), Color(0xFF5B8DEF), Color(0xFF4FD8F5)],
    [Color(0xFFC95F7F), Color(0xFFF26B8A), Color(0xFFFFB3C6)],
    [Color(0xFF4F9E7C), Color(0xFF31C27C), Color(0xFF9FF0CF)],
    [Color(0xFF5F4FC9), Color(0xFF7C6FF0), Color(0xFFB3A8FF)],
    [Color(0xFFC96F2F), Color(0xFFF2A33C), Color(0xFFFFD9A8)],
    [Color(0xFF2F8FC9), Color(0xFF4FD8F5), Color(0xFFA8F0FF)],
  ];
  return palettes[index % palettes.length];
}

/// 液态玻璃封面（网络图失败/无图时回落多彩渐变）
class JXCover extends StatelessWidget {
  final String url;
  final double size;
  final double radius;
  final int gradientIndex;

  const JXCover({
    super.key,
    required this.url,
    required this.size,
    this.radius = 0,
    this.gradientIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    final r = radius > 0 ? radius : size * 0.22;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: size * 0.12,
            offset: Offset(0, size * 0.05),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Stack(
          fit: StackFit.expand,
          children: [
            JXCoverImage(
              src: url,
              cacheWidth: (size * 2).round(),
              fallback: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: jxAlbumGradient(gradientIndex),
                  ),
                ),
                child: Icon(Icons.music_note_rounded,
                    color: Colors.white, size: size * 0.28),
              ),
            ),
            // 液态玻璃高光层
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.22),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.12),
                  ],
                  stops: const [0, 0.45, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 今日推荐横幅（设计稿 banner，compact 为手机版紧凑形态）
class JXBanner extends StatelessWidget {
  final VoidCallback onPlay;
  final bool compact;

  const JXBanner({super.key, required this.onPlay, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 18 : 24, vertical: compact ? 14 : 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0x665B8DEF),
            Color(0x384FD8F5),
            Color(0x337C6FF0),
          ],
        ),
        border: Border.all(
          color:
              isDark ? JXColors.glassStrokeDark : JXColors.glassStrokeLight,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  compact ? '今日推荐' : '今日推荐 · 三平台聚合',
                  style: TextStyle(
                    fontSize: compact ? 15.5 : 19,
                    fontWeight: FontWeight.w700,
                    color: isDark ? JXColors.textOnDark : JXColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  compact
                      ? '三平台热门聚合'
                      : 'QQ音乐 / 网易云 / 酷狗 跨平台热门一键听',
                  style: TextStyle(
                    fontSize: compact ? 10.5 : 12,
                    color: isDark
                        ? JXColors.textOnDarkSecondary
                        : JXColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onPlay,
            child: Container(
              width: compact ? 38 : 44,
              height: compact ? 38 : 44,
              decoration: const BoxDecoration(
                color: Color(0xF2FFFFFF),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x4D000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(Icons.play_arrow_rounded,
                  color: const Color(0xFF1A1F29), size: compact ? 20 : 22),
            ),
          ),
        ],
      ),
    );
  }
}

/// 区块标题（设计稿 sect：标题 + 更多）
class JXSectionHeader extends StatelessWidget {
  final String title;
  final String? moreText;
  final VoidCallback? onMore;
  final double paddingLeft;
  final double paddingRight;

  const JXSectionHeader({
    super.key,
    required this.title,
    this.moreText = '更多 ›',
    this.onMore,
    this.paddingLeft = 20,
    this.paddingRight = 16,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return Padding(
      padding: EdgeInsets.fromLTRB(paddingLeft, 14, paddingRight, 10),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          if (onMore != null)
            GestureDetector(
              onTap: onMore,
              child: Text(moreText!,
                  style: TextStyle(fontSize: 11, color: textSub)),
            ),
        ],
      ),
    );
  }
}

/// 歌曲行（设计稿 song-row：封面 + 标题/歌手 + 平台 tag + 时长）
class SongRow extends StatelessWidget {
  final String title;
  final String artist;
  final String tag;
  final Color tagColor;
  final String durationText;
  final String coverUrl;
  final int gradientIndex;
  final VoidCallback onTap;
  final bool compact;
  final Widget? trailing;

  const SongRow({
    super.key,
    required this.title,
    required this.artist,
    required this.tag,
    required this.tagColor,
    required this.durationText,
    required this.coverUrl,
    required this.gradientIndex,
    required this.onTap,
    this.compact = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    final thumb = compact ? 34.0 : 40.0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: compact ? 8 : 8),
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 11 : 14, vertical: compact ? 8 : 9),
        decoration: BoxDecoration(
          color: (isDark ? JXColors.glassDark : JXColors.glassLight)
              .withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: isDark ? JXColors.glassStrokeDark : JXColors.glassStrokeLight,
          ),
        ),
        child: Row(
          children: [
            JXCover(
                url: coverUrl, size: thumb, radius: 11, gradientIndex: gradientIndex),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: compact ? 12.5 : 13,
                        fontWeight: FontWeight.w600,
                        color: textColor),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: textSub),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
              decoration: BoxDecoration(
                color: tagColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                tag,
                style: TextStyle(
                    fontSize: 10, color: tagColor, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 10),
            Text(durationText,
                style: TextStyle(fontSize: 11, color: textSub)),
            if (trailing != null) ...[
              const SizedBox(width: 6),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
