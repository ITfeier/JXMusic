import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/download_service.dart';
import '../services/library_store.dart';
import '../services/playback.dart';
import 'dialogs.dart';
import 'glass.dart';
import 'layout.dart';
import 'my_playlist_page.dart';
import 'playlist_detail_page.dart';
import 'playlist_row.dart';

/// 收藏歌单 tab「去登录」跳转的壳层 tab 下标（顺序必须与 shell_page
/// 的 navItems/pages 一致：首页/搜索/音乐库/本地/设置）。
const int _navSettingsIndex = 4;

/// 音乐库（2026-11-18 重排）：一级「音乐 / 歌单 / 下载」三个等宽 tab；
/// 音乐内二级「收藏 / 历史」，歌单内二级「收藏 / 创建」；歌单卡片手机端一排 3 个。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  /// 一级分类：0=音乐 1=歌单 2=下载
  int _tab = 0;

  /// 音乐二级：0=收藏歌曲 1=播放历史
  int _musicSub = 0;

  /// 歌单二级：0=收藏歌单（本机收藏+平台聚合） 1=自建歌单
  int _playlistSub = 0;

  List<DownloadedEntry> _downloads = const [];
  bool _downloadsLoading = false;
  String? _downloadsError;

  List<Playlist> _collected = const [];
  bool _collectedLoading = false;
  String? _collectedError;
  Map<int, String> _platformStatus = const {};

  /// 登录会话已失效（登录已过期/风控）的平台：chip 置为警示色，
  /// 点击同样跳设置页重新登录。
  Set<int> _platformErrors = const {};

  Future<void> _playFrom(List<Song> songs, int index) async {
    final ok = await resolveAndPlay(ref, songs[index], queue: songs);
    if (!ok && mounted) {
      jxShowNotice(context, '无法播放：该歌曲可能需要先在设置里登录对应平台');
    }
  }

  void _switchTab(int index) {
    setState(() => _tab = index);
    // 下载目录可能在别的页面新增了文件，切到下载页时重新扫描
    if (index == 2) _loadDownloads();
    // 歌单默认二级是「收藏」：登录态可能在设置页变化，重新拉取
    if (index == 1 && _playlistSub == 0) _loadCollected();
  }

  /// 切到歌单二级「收藏」时重新聚合平台歌单（登录态可能刚在设置页变化）
  void _switchPlaylistSub(int index) {
    setState(() => _playlistSub = index);
    if (index == 0) _loadCollected();
  }

  /// 聚合各登录平台用户的创建/收藏歌单（轮询交错：QQ/网易/酷狗 A1,B1,C1,A2…）。
  ///
  /// 未登录的平台跳过拉取并标记「未登录」；登录的平台展示拉到的歌单数，
  /// 让「为什么这个平台是空的」一眼可见，而不是静默空白。
  Future<void> _loadCollected() async {
    if (_collectedLoading) return;
    setState(() {
      _collectedLoading = true;
      _collectedError = null;
    });
    const platforms = [
      JXPlatform.qq,
      JXPlatform.netease,
      JXPlatform.kugou,
    ];
    try {
      final hub = ref.read(musicHubProvider);
      final byPlatform = await hub.userPlaylistsByPlatform();
      final status = <int, String>{};
      final errors = <int>{};
      for (final p in platforms) {
        final loggedIn = ref.read(accountProvider(p)) != null;
        final result = byPlatform[p];
        if (!loggedIn) {
          status[p] = '未登录';
        } else if (result != null && result.hasError) {
          // 已登录但平台拒绝该会话（如「登录已过期」）：展示真实原因，
          // 而不是误导性的「0 个歌单」
          status[p] = result.error!;
          errors.add(p);
        } else {
          status[p] = '${result?.playlists.length ?? 0} 个歌单';
        }
      }
      final lists = [
        for (final p in platforms)
          (byPlatform[p]?.playlists ?? const <Playlist>[]).toList(),
      ];
      final merged = <Playlist>[];
      var hasMore = true;
      while (hasMore) {
        hasMore = false;
        for (final list in lists) {
          if (list.isNotEmpty) {
            merged.add(list.removeAt(0));
            hasMore = true;
          }
        }
      }
      if (mounted) {
        setState(() {
          _collected = merged;
          _platformStatus = status;
          _platformErrors = errors;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _collectedError = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _collectedLoading = false);
    }
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
    jxShowNotice(context, message);
  }

  Future<void> _createPlaylist() async {
    final name = await promptText(context, title: '新建歌单', hint: '歌单名称');
    if (name == null || !mounted) return;
    ref.read(libraryProvider).createPlaylist(name);
    if (mounted) {
      jxShowNotice(context, '已创建歌单「$name」');
    }
  }

  /// 导入歌单：解析分享链接 → 拉取歌单全部歌曲 → 存为本地自建歌单
  Future<void> _importPlaylist() async {
    final link = await promptText(
      context,
      title: '导入歌单',
      hint: '粘贴网易云 / QQ / 酷狗歌单链接或 ID',
      maxLength: 500,
    );
    if (link == null || !mounted) return;
    final parsed = parseJXPlaylistLink(link);
    if (parsed == null) {
      _toast('无法识别歌单链接，请粘贴网易云 / QQ / 酷狗歌单分享链接');
      return;
    }
    final api = ref.read(musicHubProvider).api(parsed.platform);
    if (api == null) {
      _toast('该平台暂不可用');
      return;
    }
    _toast('正在导入歌单…');
    final src = Playlist(
      id: parsed.id,
      platform: parsed.platform,
      title: '',
    );
    // 源歌单元数据（名称/封面）：把分享链接的原始信息带过来，
    // 拉不到（平台不支持/接口失败）不阻塞，走手填名称兜底。
    final info = await api.playlistInfo(src);
    final songs = await api.playlistSongs(src);
    if (!mounted) return;
    if (songs.isEmpty) {
      _toast('导入失败：歌单为空或链接无效（部分平台需先登录）');
      return;
    }
    final infoTitle = (info?.title ?? '').trim();
    final name = await promptText(
      context,
      title: '歌单名称',
      initial: infoTitle.isNotEmpty ? infoTitle : '导入歌单',
      hint: '歌单名称',
    );
    if (name == null || !mounted) return;
    final store = ref.read(libraryProvider);
    final playlistId =
        store.createPlaylist(name, coverUrl: info?.coverUrl ?? '');
    for (final song in songs) {
      store.addSongToPlaylist(playlistId, song);
    }
    _toast('已导入 ${songs.length} 首到「$name」');
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(libraryProvider);
    // 从设置页登录/退出后返回音乐库（IndexedStack 不重建页面）时，
    // 歌单「收藏」二级的登录态已变化，重新拉取让状态 chip 立即反映。
    ref.listen<int>(navIndexProvider, (previous, next) {
      if (next == 2 && _tab == 1 && _playlistSub == 0) {
        _loadCollected();
      }
    });
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return Column(
      children: [
        Padding(
          // 顶部安全区由壳层 MobilePageSafeArea 统一避让（手机端为 0）；
          // 桌面端保持原来的 18dp，桌面布局零变化。
          padding: EdgeInsets.fromLTRB(
            20,
            jxPageTopInset(context, desktop: 18),
            16,
            10,
          ),
          child: LayoutBuilder(builder: (context, constraints) {
            // 窄屏（手机 360~390dp 级）下「导入歌单 + 新建歌单」两个文字
            // 按钮连同标题放不下一行（会 RenderFlex overflow），换成图标按钮。
            final compact = constraints.maxWidth < 380;
            return Row(
              children: [
                const Text(
                  '音乐库',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (_tab == 0 && _musicSub == 1 && store.history.isNotEmpty)
                  GlassButton(
                    text: '清空历史',
                    height: 36,
                    onPressed: () => _confirmClearHistory(store),
                  ),
                if (_tab == 1 && _playlistSub == 0)
                  GlassIconButton(
                    icon: Icons.refresh_rounded,
                    size: 36,
                    onPressed: _loadCollected,
                  ),
                if (_tab == 1 && _playlistSub == 1) ...[
                  if (compact) ...[
                    Tooltip(
                      message: '导入歌单',
                      child: GlassIconButton(
                        icon: Icons.download_rounded,
                        size: 34,
                        onPressed: _importPlaylist,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: '新建歌单',
                      child: GlassIconButton(
                        icon: Icons.add_rounded,
                        size: 34,
                        onPressed: _createPlaylist,
                      ),
                    ),
                  ] else ...[
                    GlassButton(
                      text: '导入歌单',
                      height: 36,
                      icon: Icons.download_rounded,
                      onPressed: _importPlaylist,
                    ),
                    const SizedBox(width: 8),
                    GlassButton(
                      text: '新建歌单',
                      height: 36,
                      icon: Icons.add_rounded,
                      onPressed: _createPlaylist,
                    ),
                  ],
                ],
                if (_tab == 2)
                  GlassIconButton(
                    icon: Icons.refresh_rounded,
                    size: 36,
                    onPressed: _loadDownloads,
                  ),
              ],
            );
          }),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _TabChip(
                  text: '音乐',
                  selected: _tab == 0,
                  onTap: () => _switchTab(0),
                  centered: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TabChip(
                  text: '歌单',
                  selected: _tab == 1,
                  onTap: () => _switchTab(1),
                  centered: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TabChip(
                  text: '下载',
                  selected: _tab == 2,
                  onTap: () => _switchTab(2),
                  centered: true,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_tab) {
            0 => _buildMusic(store, textSub),
            1 => _buildPlaylistBoard(store, textSub),
            _ => _buildDownloads(textSub),
          },
        ),
      ],
    );
  }

  /// 收藏歌单：本机收藏（歌单详情页「收藏」保存）+ 各登录平台用户歌单聚合。
  /// 顶部按平台展示拉取状态（未登录/歌单数），平台歌单里已本机收藏的不再重复。
  Widget _buildCollected(LibraryStore store, Color textSub) {
    if (_collectedLoading) {
      return const Center(
          child: CircularProgressIndicator(color: JXColors.primary));
    }
    if (_collectedError != null) {
      return _EmptyHint(
        icon: Icons.error_outline_rounded,
        text: _collectedError!,
        textSub: textSub,
      );
    }
    final collected = store.collectedPlaylists;
    final platformLists = [
      for (final p in _collected)
        if (!store.isCollected(p)) p,
    ];
    // LayoutBuilder 必须在 SingleChildScrollView 的 16dp 内边距内层：
    // 用 Wrap 的真实可用宽度算列宽，否则卡片按全宽算、第 3 张被挤到下一行。
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      child: LayoutBuilder(builder: (context, constraints) {
        const spacing = 12.0;
        // 手机端一排 3 个（用户要求）；桌面宽内容区维持自适应多列
        // （阈值 808 = 原 840 - 左右内边距 32，桌面行为不变）。
        final columns = constraints.maxWidth >= 808
            ? (constraints.maxWidth / (128 + spacing)).floor().clamp(1, 8)
            : 3;
        final cardWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        Widget cards(List<Playlist> lists) => Wrap(
              spacing: spacing,
              runSpacing: 16,
              children: [
                for (var i = 0; i < lists.length; i++)
                  JXPlaylistCard(
                    playlist: lists[i],
                    width: cardWidth,
                    gradientIndex: i,
                    onTap: (playlist) => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistDetailPage(playlist: playlist),
                      ),
                    ),
                  ),
              ],
            );
        Widget sectionTitle(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(2, 14, 0, 10),
              child: Text(
                text,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: textSub),
              ),
            );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 各平台拉取状态：未登录 / 歌单数一目了然；
            // 未登录的平台点击 chip 直接跳设置页登录。
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final p in const [
                  JXPlatform.qq,
                  JXPlatform.netease,
                  JXPlatform.kugou,
                ])
                  _PlatformStatusChip(
                    platform: p,
                    status: _platformStatus[p],
                    error: _platformErrors.contains(p),
                    onTap: _platformStatus[p] == '未登录' ||
                            _platformErrors.contains(p)
                        ? () => ref
                            .read(navIndexProvider.notifier)
                            .state = _navSettingsIndex
                        : null,
                  ),
              ],
            ),
            if (collected.isNotEmpty) ...[
              sectionTitle('本机收藏 ${collected.length}'),
              cards(collected),
            ],
            if (platformLists.isNotEmpty) ...[
              sectionTitle('平台账号歌单'),
              cards(platformLists),
            ],
            if (collected.isEmpty && platformLists.isEmpty) ...[
              _EmptyHint(
                icon: Icons.library_music_rounded,
                text: '还没有收藏的歌单\n在歌单详情页点「收藏」保存到本机；登录平台账号后\n这里还会聚合你在各平台创建和收藏的歌单',
                textSub: textSub,
              ),
              if (const [
                JXPlatform.qq,
                JXPlatform.netease,
                JXPlatform.kugou,
              ].any((p) =>
                  _platformStatus[p] == '未登录' ||
                  _platformErrors.contains(p)))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: GlassButton(
                    text: '去设置登录',
                    height: 38,
                    icon: Icons.login_rounded,
                    onPressed: () => ref
                        .read(navIndexProvider.notifier)
                        .state = _navSettingsIndex,
                  ),
                ),
            ],
          ],
        );
      }),
    );
  }

  /// 一级「音乐」：二级「收藏 / 历史」小标签 + 对应列表
  Widget _buildMusic(LibraryStore store, Color textSub) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              _TabChip(
                text: '收藏 ${store.favorites.length}',
                selected: _musicSub == 0,
                onTap: () => setState(() => _musicSub = 0),
                compact: true,
              ),
              const SizedBox(width: 8),
              _TabChip(
                text: '历史 ${store.history.length}',
                selected: _musicSub == 1,
                onTap: () => setState(() => _musicSub = 1),
                compact: true,
              ),
            ],
          ),
        ),
        Expanded(
          child: _musicSub == 0
              ? _buildFavorites(store, textSub)
              : _buildHistory(store, textSub),
        ),
      ],
    );
  }

  /// 一级「歌单」：二级「收藏 / 创建」小标签 + 对应网格
  Widget _buildPlaylistBoard(LibraryStore store, Color textSub) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              _TabChip(
                text: '收藏 ${store.collectedPlaylists.length}',
                selected: _playlistSub == 0,
                onTap: () => _switchPlaylistSub(0),
                compact: true,
              ),
              const SizedBox(width: 8),
              _TabChip(
                text: '创建 ${store.playlists.length}',
                selected: _playlistSub == 1,
                onTap: () => _switchPlaylistSub(1),
                compact: true,
              ),
            ],
          ),
        ),
        Expanded(
          child: _playlistSub == 0
              ? _buildCollected(store, textSub)
              : _buildMyPlaylists(store, textSub),
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

  /// 歌单二级「创建」：自建歌单卡片网格（与「收藏」同视觉，手机一排 3 个）。
  /// 卡片长按弹出重命名 / 删除菜单（原列表行的 PopupMenu 降级入口）。
  Widget _buildMyPlaylists(LibraryStore store, Color textSub) {
    if (store.playlists.isEmpty) {
      return _EmptyHint(
        icon: Icons.queue_music_rounded,
        text: '还没有自建歌单\n点右上角「新建歌单」开始整理',
        textSub: textSub,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      child: LayoutBuilder(builder: (context, constraints) {
        const spacing = 12.0;
        // 同「收藏」二级：手机一排 3 个，桌面自适应（阈值 808 见上）。
        final columns = constraints.maxWidth >= 808
            ? (constraints.maxWidth / (128 + spacing)).floor().clamp(1, 8)
            : 3;
        final cardWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: 16,
          children: [
            for (var i = 0; i < store.playlists.length; i++)
              _LocalPlaylistCard(
                playlist: store.playlists[i],
                width: cardWidth,
                gradientIndex: i,
                onTap: (playlist) => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MyPlaylistPage(playlistId: playlist.id),
                  ),
                ),
                onLongPress: _showPlaylistMenu,
              ),
          ],
        );
      }),
    );
  }

  /// 自建歌单卡片长按菜单：底部弹层「重命名 / 删除歌单」
  Future<void> _showPlaylistMenu(UserPlaylist playlist) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('删除歌单'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final store = ref.read(libraryProvider);
    if (action == 'rename') {
      final name = await promptText(context,
          title: '重命名歌单', initial: playlist.name, hint: '歌单名称');
      if (name != null) store.renamePlaylist(playlist.id, name);
    } else if (action == 'delete') {
      final ok = await confirmAction(
        context,
        title: '删除歌单',
        content: '确定删除「${playlist.name}」吗？歌单内的歌曲不会被删除。',
      );
      if (ok) store.deletePlaylist(playlist.id);
    }
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

/// 解析歌单分享链接 / 歌单 ID → (平台, 歌单 id)。识别失败返回 null。
///
/// 支持的链接形态（2026-11 各平台分享格式）：
/// · 网易云 music.163.com/#/playlist?id=xxx（id 在 fragment 的 query 里）
/// · QQ 音乐 y.qq.com/n/ryqq/playlist/XXXX
/// · 酷狗 m.kugou.com/songlist/gcid_XXX/（gcid 在路径）/ ?specialid=xxx / global_collection_id=xxx / id=xxx
/// · 纯数字：按网易云歌单 id 处理
({int platform, String id})? parseJXPlaylistLink(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  if (text.contains('163.com') || text.contains('163cn')) {
    final id = RegExp(r'[?&]id=(\d+)').firstMatch(text)?.group(1);
    if (id != null && id.isNotEmpty) {
      return (platform: JXPlatform.netease, id: id);
    }
  }
  if (text.contains('qq.com')) {
    final id = RegExp(r'playlist/([A-Za-z0-9]+)').firstMatch(text)?.group(1) ??
        RegExp(r'[?&]id=([A-Za-z0-9]+)').firstMatch(text)?.group(1);
    if (id != null && id.isNotEmpty) {
      return (platform: JXPlatform.qq, id: id);
    }
  }
  if (text.contains('kugou.com')) {
    // m.kugou.com/songlist/gcid_XXX/：gcid（全球集合 ID）在路径里，字母数字混合；
    // 2026-11 实测 App/网页分享链接都是这种形态，查歌时由 KuGouApi 先经歌单页
    // 映射成数字 specialid。global_collection_id 参数同样放宽到字母数字。
    final gcid = RegExp(r'/songlist/gcid_([A-Za-z0-9]+)')
                .firstMatch(text)
                ?.group(1) ??
        RegExp(r'[?&]global_collection_id=([A-Za-z0-9]+)')
            .firstMatch(text)
            ?.group(1);
    if (gcid != null && gcid.isNotEmpty) {
      return (platform: JXPlatform.kugou, id: gcid);
    }
    final id = RegExp(r'[?&]specialid=(\d+)').firstMatch(text)?.group(1) ??
        RegExp(r'[?&]id=(\d+)').firstMatch(text)?.group(1);
    if (id != null && id.isNotEmpty) {
      return (platform: JXPlatform.kugou, id: id);
    }
  }
  if (RegExp(r'^\d+$').hasMatch(text)) {
    return (platform: JXPlatform.netease, id: text);
  }
  return null;
}

/// 圆角标签 chip。一级 tab 用默认尺寸（[centered] 等宽居中），
/// 二级小分类用 [compact] 缩小内距与字号。
class _TabChip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;

  /// 二级小标签：更紧凑的内距与字号
  final bool compact;

  /// 一级等宽布局（Expanded）下让文本居中
  final bool centered;

  const _TabChip({
    required this.text,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.centered = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = Text(
      text,
      style: TextStyle(
        fontSize: compact ? 11.5 : 12.5,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
        color: selected
            ? JXColors.primary
            : (isDark ? JXColors.textOnDark : JXColors.textPrimary),
      ),
    );
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16,
          vertical: compact ? 6 : 8,
        ),
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
        child: centered ? Center(child: label) : label,
      ),
    );
  }
}

/// 自建歌单卡片：与 JXPlaylistCard 同视觉（无网络封面 → 渐变占位），
/// 长按弹重命名 / 删除菜单。
class _LocalPlaylistCard extends StatelessWidget {
  final UserPlaylist playlist;
  final double width;
  final int gradientIndex;
  final void Function(UserPlaylist) onTap;
  final void Function(UserPlaylist) onLongPress;

  const _LocalPlaylistCard({
    required this.playlist,
    required this.width,
    required this.gradientIndex,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onTap(playlist),
      onLongPress: () => onLongPress(playlist),
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
                  // 导入歌单带过来的源封面；空串走渐变占位
                  url: playlist.coverUrl,
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
                      '${playlist.songCount} 首',
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
              playlist.name,
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
    // 矮屏（横屏 640x360 时内容区只剩约 190dp）下空态放不下会触发
    // RenderFlex overflow；Center + SingleChildScrollView 保证常规屏宽高下
    // 仍然居中、矮屏时可滚动，不遮挡内容。
    return Center(
      child: SingleChildScrollView(
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

/// 收藏歌单页顶部：按平台展示登录账号歌单拉取状态（歌单数/未登录）。
class _PlatformStatusChip extends StatelessWidget {
  final int platform;
  final String? status;

  /// 登录会话已失效（「登录已过期」等）：警示色展示，点击跳设置页重登。
  final bool error;

  /// 未登录/会话失效时非空：点击跳设置页重新登录。
  final VoidCallback? onTap;

  const _PlatformStatusChip({
    required this.platform,
    required this.status,
    this.error = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    final isOff = status == '未登录';
    // 会话失效：琥珀警示色，区别于正常平台色和灰色「未登录」
    const warn = Color(0xFFF59E0B);
    final color = error ? warn : JXPlatform.color(platform);
    final text =
        status == null ? JXPlatform.name(platform) : '${JXPlatform.name(platform)} · $status';
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isOff ? Colors.transparent : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isOff
              ? textSub.withValues(alpha: 0.35)
              : color.withValues(alpha: 0.45),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: isOff ? textSub : color,
          fontWeight: isOff ? FontWeight.w400 : FontWeight.w500,
        ),
      ),
    );
    if (onTap == null) return chip;
    return Tooltip(
      message: isOff ? '去设置登录' : '去设置重新登录',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: chip,
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
