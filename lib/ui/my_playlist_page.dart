import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/playback.dart';
import 'dialogs.dart';
import 'glass.dart';
import 'player/player_bar.dart';

/// 自建歌单详情页
class MyPlaylistPage extends ConsumerWidget {
  final String playlistId;

  const MyPlaylistPage({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(libraryProvider);
    final playlist = store.playlistById(playlistId);
    if (playlist == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('歌单不存在或已被删除'),
              const SizedBox(height: 12),
              GlassButton(
                text: '返回',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    final songs = playlist.songs;

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
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                child: Row(
                  children: [
                    GlassIconButton(
                      icon: Icons.arrow_back_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '歌单详情',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert_rounded,
                          size: 20, color: textSub),
                      onSelected: (action) async {
                        if (action == 'rename') {
                          final name = await promptText(
                            context,
                            title: '重命名歌单',
                            initial: playlist.name,
                            hint: '歌单名称',
                          );
                          if (name != null) store.renamePlaylist(playlist.id, name);
                        } else if (action == 'delete') {
                          final ok = await confirmAction(
                            context,
                            title: '删除歌单',
                            content: '确定删除「${playlist.name}」吗？歌单内的歌曲不会被删除。',
                          );
                          if (ok) {
                            store.deletePlaylist(playlist.id);
                            if (context.mounted) Navigator.of(context).pop();
                          }
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'delete', child: Text('删除歌单')),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [JXColors.primary, JXColors.accentCyan],
                        ),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: const Icon(Icons.queue_music_rounded,
                          color: Colors.white, size: 44),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            playlist.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: textColor),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${playlist.songCount} 首 · 我的歌单',
                            style: TextStyle(fontSize: 12, color: textSub),
                          ),
                          const SizedBox(height: 12),
                          GlassButton(
                            text: '播放全部',
                            icon: Icons.play_arrow_rounded,
                            primary: true,
                            onPressed: songs.isEmpty
                                ? null
                                : () => _playAll(context, ref, songs),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: songs.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            '歌单还是空的\n在播放页「⋯」菜单里可以添加当前歌曲',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13, height: 1.6, color: textSub),
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                        itemCount: songs.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, indent: 60),
                        itemBuilder: (context, i) {
                          final song = songs[i];
                          return ListTile(
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            leading: SizedBox(
                              width: 32,
                              child: Text(
                                '${i + 1}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: i < 3
                                      ? JXColors.accentPink
                                      : textSub,
                                ),
                              ),
                            ),
                            title: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 14,
                                  color: textColor,
                                  fontWeight: FontWeight.w500),
                            ),
                            subtitle: Text(
                              song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  TextStyle(fontSize: 11, color: textSub),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GlassIconButton(
                                  icon: Icons.play_arrow_rounded,
                                  size: 36,
                                  color: JXColors.primary,
                                  onPressed: () =>
                                      _play(context, ref, songs, i),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: Icon(Icons.remove_circle_outline_rounded,
                                      size: 20, color: textSub),
                                  tooltip: '从歌单移除',
                                  onPressed: () => store.removeSongFromPlaylist(
                                      playlist.id, song),
                                ),
                              ],
                            ),
                            onTap: () => _play(context, ref, songs, i),
                          );
                        },
                      ),
              ),
              // 底部常驻迷你播放条：本页是 Navigator.push 的整页路由，
              // 会盖住 ShellPage 上的 PlayerBar，所以本页要自带一份。
              const PlayerBar(),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _play(
      BuildContext context, WidgetRef ref, List<Song> songs, int index) async {
    final ok = await resolveAndPlay(ref, songs[index], queue: songs);
    if (!ok && context.mounted) {
      jxShowNotice(context, '无法播放：该歌曲可能需要先在设置里登录对应平台');
    }
  }

  Future<void> _playAll(
      BuildContext context, WidgetRef ref, List<Song> songs) async {
    if (songs.isEmpty) return;
    final ok = await resolveAndPlay(ref, songs.first, queue: songs);
    if (!ok && context.mounted) {
      jxShowNotice(context, '无法播放：该歌曲可能需要先在设置里登录对应平台');
    }
  }
}
