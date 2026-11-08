import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../models/playlist.dart';
import 'layout.dart';

/// 歌单卡片（首页横滑与「全部歌单」网格共用同一视觉）：
/// 方形封面 + 左下角「平台 · 曲目数」角标 + 单行标题。
class JXPlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final double width;
  final int gradientIndex;
  final void Function(Playlist) onTap;

  const JXPlaylistCard({
    super.key,
    required this.playlist,
    required this.width,
    required this.gradientIndex,
    required this.onTap,
  });

  static String platformShort(int platform) {
    switch (platform) {
      case JXPlatform.netease:
        return '网易云';
      case JXPlatform.kugou:
        return '酷狗';
      case JXPlatform.qq:
        return 'QQ音乐';
      default:
        return '本地';
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = playlist;
    final countText = p.songCount > 0 ? ' · ${p.songCount} 首' : '';
    return GestureDetector(
      onTap: () => onTap(p),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                JXCover(
                  url: p.coverUrl,
                  size: width,
                  radius: 16,
                  gradientIndex: gradientIndex,
                ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${platformShort(p.platform)}$countText',
                      style: const TextStyle(
                          fontSize: 9.5,
                          color: Colors.white,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              p.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单平台推荐歌单横滑卡片（首页桌面/手机共用）
class JXPlaylistRow extends StatelessWidget {
  final List<Playlist> playlists;
  final double cardWidth;
  final void Function(Playlist) onTap;

  const JXPlaylistRow({
    super.key,
    required this.playlists,
    required this.cardWidth,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    if (playlists.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: Text(
          '暂无歌单（平台接口可能调整），点右侧「更多」查看全部歌单',
          style: TextStyle(fontSize: 12, color: textSub),
        ),
      );
    }

    return SizedBox(
      height: cardWidth + 36,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: playlists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) => JXPlaylistCard(
          playlist: playlists[i],
          width: cardWidth,
          gradientIndex: i,
          onTap: onTap,
        ),
      ),
    );
  }
}
