import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../providers.dart';
import '../services/mini_mode.dart';
import 'glass.dart';

/// 迷你播放窗口（约 420x150）：拖动移动、播放控制、返回主界面、收进托盘
class MiniPlayerPage extends ConsumerWidget {
  const MiniPlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);
    final song = player.currentSong;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    final progress = player.duration.inMilliseconds > 0
        ? (player.position.inMilliseconds / player.duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => MiniMode.startDrag(),
        child: Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [const Color(0xEE151B29), const Color(0xEE0B0E16)]
                  : [const Color(0xEEF3F6FC), const Color(0xEEE2E9F5)],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? JXColors.glassStrokeDark
                  : JXColors.glassStrokeLight,
            ),
          ),
          child: song == null
              ? Center(
                  child: Text('未在播放',
                      style: TextStyle(fontSize: 13, color: textSub)),
                )
              : Row(
                  children: [
                    GestureDetector(
                      onTap: () {},
                      child: GlassCover(
                        url: song.coverUrl,
                        size: 62,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10.5, color: textSub),
                          ),
                          const SizedBox(height: 7),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 2.5,
                              backgroundColor: isDark
                                  ? Colors.white.withValues(alpha: 0.12)
                                  : Colors.black.withValues(alpha: 0.08),
                              valueColor: const AlwaysStoppedAnimation(
                                  JXColors.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    GlassIconButton(
                      icon: Icons.skip_previous_rounded,
                      size: 30,
                      onPressed: () => player.previous(),
                    ),
                    const SizedBox(width: 2),
                    GlassIconButton(
                      icon: player.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 36,
                      color: JXColors.primary,
                      onPressed: () => player.toggle(),
                    ),
                    const SizedBox(width: 2),
                    GlassIconButton(
                      icon: Icons.skip_next_rounded,
                      size: 30,
                      onPressed: () => player.next(),
                    ),
                    const SizedBox(width: 4),
                    GlassIconButton(
                      icon: Icons.open_in_full_rounded,
                      size: 28,
                      onPressed: () async {
                        await MiniMode.exit();
                        ref.read(miniModeProvider.notifier).state = false;
                      },
                    ),
                    GlassIconButton(
                      icon: Icons.close_rounded,
                      size: 28,
                      onPressed: () => MiniMode.hideToTray(),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
