import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../core/constants.dart';
import '../glass.dart';
import 'player_page.dart';

/// 迷你播放条（底部常驻）
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);
    final song = player.currentSong;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (song == null) {
      // 空态：常驻迷你播放条占位（符合设计稿底部播放条）
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 16, 12),
        child: GlassCard(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          borderRadius: BorderRadius.circular(22),
          blur: 24,
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: (isDark ? JXColors.glassDark : JXColors.glassLight)
                      .withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.music_note_rounded,
                    color: JXColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '未在播放',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? JXColors.textOnDark
                            : JXColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '点击导航栏切换曲库开始播放',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? JXColors.textOnDarkSecondary
                            : JXColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              GlassIconButton(
                icon: Icons.play_arrow_rounded,
                size: 40,
                color: JXColors.primary,
                onPressed: () {},
              ),
              const SizedBox(width: 4),
              GlassIconButton(
                icon: Icons.skip_next_rounded,
                size: 36,
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
    }

    final position = player.position;
    final duration = player.duration;
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 16, 12),
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const PlayerPage(),
          ));
        },
        child: GlassCard(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          borderRadius: BorderRadius.circular(22),
          blur: 24,
          child: Row(
            children: [
              GlassCover(
                url: song.coverUrl,
                size: 48,
                borderRadius: BorderRadius.circular(12),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? JXColors.textOnDark
                            : JXColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${song.artist} · ${song.displayPlatform}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? JXColors.textOnDarkSecondary
                            : JXColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0, 1),
                        minHeight: 2.5,
                        backgroundColor: isDark
                            ? Colors.white.withValues(alpha: 0.12)
                            : Colors.black.withValues(alpha: 0.08),
                        valueColor: const AlwaysStoppedAnimation(JXColors.primary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: player.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                size: 40,
                color: JXColors.primary,
                onPressed: () => player.toggle(),
              ),
              const SizedBox(width: 4),
              GlassIconButton(
                icon: Icons.skip_next_rounded,
                size: 36,
                onPressed: () => player.next(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
