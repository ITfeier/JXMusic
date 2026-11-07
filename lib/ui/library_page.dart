import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/download_service.dart';
import '../services/library_store.dart';
import '../services/playback.dart';
import 'dialogs.dart';
import 'glass.dart';
import 'layout.dart';
import 'my_playlist_page.dart';

/// 音乐库：收藏 / 播放历史 / 我的歌单 / 已下载
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  int _tab = 0;

  List<DownloadedEntry> _downloads = const [];
  bool _downloadsLoading = false;
  String? _downloadsError;

  Future<void> _playFrom(List<Song> songs, int index) async {
    final ok = await resolveAndPlay(ref, songs[index], queue: songs);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('无法播放：该歌曲可能需要先在设置里登录对应平台'),
      ));
    }
  }

  void _switchTab(int index) {
    setState(() => _tab = index);
    // 下载目录可能在别的页面新增了文件，切到下载页时重新扫描
    if (index == 3) _loadDownloads();
  }

  Future<void> _loadDownloads() async {
    if (_downloadsLoading) return;
    setState(() {
      _downloadsLoading = true;
      _downloadsError = null;
    });
    try {
      final list = await DownloadService.instance.listDownloaded();
      if (mounted) setState(() => _downloads = list);
    } catch (e) {
      if (mounted) setState(() => _downloadsError = '读取下载目录失败：$e');
    } finally {
      if (mounted) setState(() => _downloadsLoading = false);
    }
  }

  Future<void> _openDownloadFolder() async {
    try {
      final dir = await DownloadService.instance.targetDirectory();
      if (Platform.isWindows) {
        await Process.run('explorer', [dir.path]);
      } else if (mounted) {
        _toast('下载目录：${dir.path}');
      }
    } catch (e) {
      if (mounted) _toast('无法打开下载目录：$e');
    }
  }

  Future<void> _revealFile(DownloadedEntry entry) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', entry.file.path]);
      } else if (mounted) {
        _toast('文件位置：${entry.file.path}');
      }
    } catch (e) {
      if (mounted) _toast('无法定位文件：$e');
    }
  }

  Future<void> _deleteDownload(DownloadedEntry entry) async {
    final ok = await confirmAction(
      context,
      title: '删除已下载文件',
      content: '确定删除「${entry.song.title}」的本地文件吗？',
    );
    if (!ok) return;
    try {
      await DownloadService.instance.deleteDownload(entry);
      await _loadDownloads();
      if (mounted) _toast('已删除本地文件');
    } catch (e) {
      if (mounted) _toast('删除失败：$e');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
              if (_tab == 3)
                GlassIconButton(
                  icon: Icons.refresh_rounded,
                  size: 36,
                  onPressed: _loadDownloads,
                ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _TabChip(
                text: '收藏 ${store.favorites.length}',
                selected: _tab == 0,
                onTap: () => _switchTab(0),
              ),
              const SizedBox(width: 8),
              _TabChip(
                text: '历史 ${store.history.length}',
                selected: _tab == 1,
                onTap: () => _switchTab(1),
              ),
              const SizedBox(width: 8),
              _TabChip(
                text: '歌单 ${store.playlists.length}',
                selected: _tab == 2,
                onTap: () => _switchTab(2),
              ),
              const SizedBox(width: 8),
              _TabChip(
                text: '下载 ${_downloads.length}',
                selected: _tab == 3,
                onTap: () => _switchTab(3),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_tab) {
            0 => _buildFavorites(store, textSub),
            1 => _buildHistory(store, textSub),
            2 => _buildPlaylists(store, textSub),
            _ => _buildDownloads(textSub),
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

  Widget _buildDownloads(Color textSub) {
    if (_downloadsLoading) {
      return const Center(
          child: CircularProgressIndicator(color: JXColors.primary));
    }
    if (_downloadsError != null) {
      return _EmptyHint(
        icon: Icons.error_outline_rounded,
        text: _downloadsError!,
        textSub: textSub,
      );
    }
    if (_downloads.isEmpty) {
      return _EmptyHint(
        icon: Icons.download_rounded,
        text: '还没有下载的歌曲\n在播放页「⋯」菜单里可以下载当前歌曲',
        textSub: textSub,
      );
    }
    final songs = [for (final e in _downloads) e.song];
    final totalBytes = _downloads.fold<int>(0, (sum, e) => sum + e.bytes);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 8, 0),
          child: Row(
            children: [
              Text(
                '${_downloads.length} 首 · ${_formatBytes(totalBytes)}',
                style: TextStyle(fontSize: 11.5, color: textSub),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _openDownloadFolder,
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('打开文件夹', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: _downloads.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final entry = _downloads[i];
              return SongRow(
                title: entry.song.title,
                artist: entry.song.artist,
                tag: '已下载',
                tagColor: JXColors.accentCyan,
                durationText: _formatBytes(entry.bytes),
                coverUrl: entry.song.coverUrl,
                gradientIndex: i,
                onTap: () => _playFrom(songs, i),
                trailing: PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert_rounded, size: 18, color: textSub),
                  onSelected: (action) {
                    if (action == 'reveal') {
                      _revealFile(entry);
                    } else if (action == 'delete') {
                      _deleteDownload(entry);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'reveal', child: Text('定位文件')),
                    PopupMenuItem(value: 'delete', child: Text('删除文件')),
                  ],
                ),
              );
            },
          ),
        ),
      ],
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

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
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
