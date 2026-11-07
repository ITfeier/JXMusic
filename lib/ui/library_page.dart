import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/library_store.dart';
import '../services/playback.dart';
import 'dialogs.dart';
import 'glass.dart';
import 'layout.dart';
import 'my_playlist_page.dart';

/// 音乐库：收藏 / 播放历史 / 我的歌单
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  int _tab = 0;

  Future<void> _playFrom(List<Song> songs, int index) async {
    final ok = await resolveAndPlay(ref, songs[index], queue: songs);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('无法播放：该歌曲可能需要先在设置里登录对应平台'),
      ));
    }
  }

  Future<void> _createPlaylist() async {
    final name = await promptText(context, title: '新建歌单', hint: '歌单名称');
    if (name == null || !mounted) return;
    ref.read(libraryProvider).createPlaylist(name);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已创建歌单「$name」')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(libraryProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 10),
          child: Row(
            children: [
              const Text(
                '音乐库',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (_tab == 1 && store.history.isNotEmpty)
                GlassButton(
                  text: '清空历史',
                  height: 36,
                  onPressed: () => _confirmClearHistory(store),
                ),
              if (_tab == 2)
                GlassButton(
                  text: '新建歌单',
                  height: 36,
                  icon: Icons.add_rounded,
                  onPressed: _createPlaylist,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _TabChip(
                text: '收藏 ${store.favorites.length}',
                selected: _tab == 0,
                onTap: () => setState(() => _tab = 0),
              ),
              const SizedBox(width: 8),
              _TabChip(
                text: '历史 ${store.history.length}',
                selected: _tab == 1,
                onTap: () => setState(() => _tab = 1),
              ),
              const SizedBox(width: 8),
              _TabChip(
                text: '歌单 ${store.playlists.length}',
                selected: _tab == 2,
                onTap: () => setState(() => _tab = 2),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_tab) {
            0 => _buildFavorites(store, textSub),
            1 => _buildHistory(store, textSub),
            _ => _buildPlaylists(store, textSub),
          },
        ),
      ],
    );
  }

  Widget _buildFavorites(LibraryStore store, Color textSub) {
    if (store.favorites.isEmpty) {
      return _EmptyHint(
        icon: Icons.favorite_border_rounded,
        text: '还没有收藏的歌曲\n在播放页「⋯」菜单里可以收藏当前歌曲',
        textSub: textSub,
      );
    }
    final songs = store.favorites;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: songs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final song = songs[i];
        return SongRow(
          title: song.title,
          artist: song.artist,
          tag: song.displayPlatform,
          tagColor: JXPlatform.color(song.platform),
          durationText: jxFormatDuration(song.duration),
          coverUrl: song.coverUrl,
          gradientIndex: i,
          onTap: () => _playFrom(songs, i),
          trailing: IconButton(
            icon: const Icon(Icons.favorite_rounded,
                color: JXColors.accentPink, size: 20),
            tooltip: '取消收藏',
            onPressed: () => store.toggleFavorite(song),
          ),
        );
      },
    );
  }

  Widget _buildHistory(LibraryStore store, Color textSub) {
    if (store.history.isEmpty) {
      return _EmptyHint(
        icon: Icons.history_rounded,
        text: '还没有播放记录\n听过的歌会自动出现在这里',
        textSub: textSub,
      );
    }
    final entries = store.history;
    final songs = [for (final e in entries) e.song];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final entry = entries[i];
        return SongRow(
          title: entry.song.title,
          artist: entry.song.artist,
          tag: entry.song.displayPlatform,
          tagColor: JXPlatform.color(entry.song.platform),
          durationText: _formatPlayedAt(entry.playedAt),
          coverUrl: entry.song.coverUrl,
          gradientIndex: i,
          onTap: () => _playFrom(songs, i),
          trailing: IconButton(
            icon: Icon(Icons.close_rounded, size: 18, color: textSub),
            tooltip: '从历史中移除',
            onPressed: () => store.removeHistory(entry),
          ),
        );
      },
    );
  }

  Widget _buildPlaylists(LibraryStore store, Color textSub) {
    if (store.playlists.isEmpty) {
      return _EmptyHint(
        icon: Icons.queue_music_rounded,
        text: '还没有自建歌单\n点右上角「新建歌单」开始整理',
        textSub: textSub,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: store.playlists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final playlist = store.playlists[i];
        return GlassCard(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => MyPlaylistPage(playlistId: playlist.id),
            ),
          ),
          child: ListTile(
            leading: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [JXColors.primary, JXColors.accentCyan],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.queue_music_rounded,
                  color: Colors.white, size: 24),
            ),
            title: Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${playlist.songCount} 首',
              style: TextStyle(fontSize: 11, color: textSub),
            ),
            trailing: PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, size: 20, color: textSub),
              onSelected: (action) async {
                if (action == 'rename') {
                  final name = await promptText(context,
                      title: '重命名歌单',
                      initial: playlist.name,
                      hint: '歌单名称');
                  if (name != null) store.renamePlaylist(playlist.id, name);
                } else if (action == 'delete') {
                  final ok = await confirmAction(
                    context,
                    title: '删除歌单',
                    content: '确定删除「${playlist.name}」吗？歌单内的歌曲不会被删除。',
                  );
                  if (ok) store.deletePlaylist(playlist.id);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'delete', child: Text('删除歌单')),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmClearHistory(LibraryStore store) async {
    final ok = await confirmAction(
      context,
      title: '清空播放历史',
      content: '确定清空全部播放记录吗？',
    );
    if (ok) store.clearHistory();
  }
}

/// 三选一标签
class _TabChip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;

  const _TabChip({
    required this.text,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? JXColors.primary.withValues(alpha: 0.16)
              : (isDark ? JXColors.glassDark : JXColors.glassLight)
                  .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? JXColors.primary.withValues(alpha: 0.5)
                : (isDark
                    ? JXColors.glassStrokeDark
                    : JXColors.glassStrokeLight),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected
                ? JXColors.primary
                : (isDark ? JXColors.textOnDark : JXColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color textSub;

  const _EmptyHint({
    required this.icon,
    required this.text,
    required this.textSub,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: textSub.withValues(alpha: 0.5)),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.6, color: textSub),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatPlayedAt(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final hhmm =
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  final diff = today.difference(day).inDays;
  if (diff == 0) return '今天 $hhmm';
  if (diff == 1) return '昨天 $hhmm';
  if (diff < 7) return '$diff 天前';
  return '${time.month}-${time.day}';
}
