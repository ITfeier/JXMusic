import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/lyric_hit.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../models/track_group.dart';
import '../providers.dart';
import '../services/api/music_api.dart';
import '../services/playback.dart';
import 'album_page.dart';
import 'artist_page.dart';
import 'glass.dart';
import 'layout.dart';
import 'playlist_detail_page.dart';
import 'playlist_row.dart';

/// 聚合搜索页：顶部模块 tab（单曲 / 歌单 / 歌手 / 专辑 / 歌词），每个模块把
/// QQ / 网易云 / 酷狗 三平台结果聚合展示。
/// - 单曲：合并去重成一份列表（同一首歌不再重复出现），每首保留全部平台音源；
/// - 歌单 / 歌手 / 专辑 / 歌词：三平台结果轮询交错合并；
/// - 每个模块按需加载（切到该 tab 才请求），结果随当前关键词缓存。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  static const List<String> _tabNames = ['单曲', '歌单', '歌手', '专辑', '歌词'];
  static const List<int> _searchPlatforms = [0, 1, 2];

  final TextEditingController _controller = TextEditingController();

  /// 当前模块索引：0 单曲 / 1 歌单 / 2 歌手 / 3 专辑 / 4 歌词
  int _tab = 0;
  String _keyword = '';
  bool _searched = false;

  // 各模块对「当前关键词」的独立缓存：切 tab 按需加载，切回不重复请求
  final Set<int> _loaded = {};
  final Set<int> _loading = {};
  final Map<int, String?> _errors = {};
  List<TrackGroup> _songs = const [];
  List<Playlist> _playlists = const [];
  List<Artist> _artists = const [];
  List<Album> _albums = const [];
  List<LyricHit> _lyricHits = const [];
  int _rawSongCount = 0;

  /// 搜索请求序号：连续提交两个关键词时，慢的旧请求回来不允许覆盖新结果。
  int _requestSeq = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 三平台并行取数：单平台 15s 超时、失败按空结果处理（不拖垮其它平台）。
  Future<List<List<T>>> _fetchPerPlatform<T>(
      Future<List<T>> Function(MusicPlatformApi api) call) {
    return Future.wait([
      for (final p in _searchPlatforms)
        () async {
          final api = ref.read(musicHubProvider).api(p);
          if (api == null) return <T>[];
          try {
            return await call(api).timeout(const Duration(seconds: 15));
          } catch (_) {
            return <T>[];
          }
        }(),
    ]);
  }

  /// 轮询交错合并：A1,B1,C1,A2…（平台缺数据时其余平台自动补位）
  static List<T> _interleave<T>(List<List<T>> lists) {
    final out = <T>[];
    var maxLen = 0;
    for (final l in lists) {
      if (l.length > maxLen) maxLen = l.length;
    }
    for (var i = 0; i < maxLen; i++) {
      for (final l in lists) {
        if (i < l.length) out.add(l[i]);
      }
    }
    return out;
  }

  Future<void> _search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    final seq = ++_requestSeq;
    setState(() {
      _keyword = kw;
      _searched = true;
      _loaded.clear();
      _loading.clear();
      _errors.clear();
      _songs = const [];
      _playlists = const [];
      _artists = const [];
      _albums = const [];
      _lyricHits = const [];
      _rawSongCount = 0;
    });
    await _fetchModule(_tab, seq, kw);
  }

  void _switchTab(int tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    // 已搜索过且该模块还没取过数：切到时按需加载
    if (_searched && !_loaded.contains(tab) && !_loading.contains(tab)) {
      _fetchModule(tab, _requestSeq, _keyword);
    }
  }

  Future<void> _fetchModule(int module, int seq, String kw) async {
    if (_loading.contains(module)) return;
    setState(() {
      _loading.add(module);
      _errors[module] = null;
    });
    switch (module) {
      case 0:
        await _fetchSongs(seq, kw);
      case 1:
        await _fetchPlaylists(seq, kw);
      case 2:
        await _fetchArtists(seq, kw);
      case 3:
        await _fetchAlbums(seq, kw);
      case 4:
        await _fetchLyrics(seq, kw);
    }
  }

  Future<void> _fetchSongs(int seq, String kw) async {
    // 三平台并行各取 100 条，合并后去重，最多展示 100 首
    final lists = await _fetchPerPlatform<Song>(
        (api) => api.searchSongs(kw, size: 100));
    // 期间又提交了新搜索：本次结果作废，不覆盖（spinner 也不许提前消失）
    if (seq != _requestSeq || !mounted) return;
    final all = lists.expand((e) => e).toList();
    final groups = buildTrackGroups(all).take(100).toList();
    setState(() {
      _songs = groups;
      _rawSongCount = all.length;
      _loaded.add(0);
      _loading.remove(0);
      _errors[0] =
          all.isEmpty ? '三个平台都没有返回结果，请换个关键词或检查网络' : null;
    });
  }

  Future<void> _fetchPlaylists(int seq, String kw) async {
    final lists = await _fetchPerPlatform<Playlist>(
        (api) => api.searchPlaylists(kw, size: 30));
    if (seq != _requestSeq || !mounted) return;
    final merged = _interleave(lists);
    setState(() {
      _playlists = merged;
      _loaded.add(1);
      _loading.remove(1);
      _errors[1] = merged.isEmpty ? '没有找到相关歌单，请换个关键词或检查网络' : null;
    });
  }

  Future<void> _fetchArtists(int seq, String kw) async {
    final lists = await _fetchPerPlatform<Artist>(
        (api) => api.searchArtists(kw, size: 30));
    if (seq != _requestSeq || !mounted) return;
    final merged = _interleave(lists);
    setState(() {
      _artists = merged;
      _loaded.add(2);
      _loading.remove(2);
      _errors[2] = merged.isEmpty ? '没有找到相关歌手，请换个关键词或检查网络' : null;
    });
  }

  Future<void> _fetchAlbums(int seq, String kw) async {
    final lists = await _fetchPerPlatform<Album>(
        (api) => api.searchAlbums(kw, size: 30));
    if (seq != _requestSeq || !mounted) return;
    final merged = _interleave(lists);
    setState(() {
      _albums = merged;
      _loaded.add(3);
      _loading.remove(3);
      _errors[3] = merged.isEmpty ? '没有找到相关专辑，请换个关键词或检查网络' : null;
    });
  }

  Future<void> _fetchLyrics(int seq, String kw) async {
    final lists = await _fetchPerPlatform<LyricHit>(
        (api) => api.searchLyrics(kw, size: 30));
    if (seq != _requestSeq || !mounted) return;
    final merged = _interleave(lists);
    setState(() {
      _lyricHits = merged;
      _loaded.add(4);
      _loading.remove(4);
      _errors[4] = merged.isEmpty ? '没有找到相关歌词，请换个关键词或检查网络' : null;
    });
  }

  /// 播放：默认用列表里标「首选」的音源；点了某个平台标签则用该平台。
  Future<void> _play(TrackGroup group, {Song? preferred}) async {
    final target = preferred ?? group.primary;
    final ok = await playTrackGroup(ref, group.sources, preferred: target);
    if (!mounted) return;
    if (ok) {
      // 首选音源解析失败时可能已自动换到本曲目的其它平台音源，明确告知用户
      final actual = ref.read(playerServiceProvider).currentSong;
      if (actual != null &&
          actual.globalId != target.globalId &&
          actual.platform != target.platform) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已改用 ${JXPlatform.name(actual.platform)} 音源播放'),
        ));
      }
      return;
    }
    final tried = group.sources.length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('「${group.title}」已尝试全部 $tried 个音源，均不可用'
          '（可能需要登录或受版权限制）'),
    ));
  }

  /// 播放歌词命中的歌曲（队列 = 当前歌词结果的所有命中歌曲）
  Future<void> _playLyricHit(LyricHit hit) async {
    final queue = [for (final h in _lyricHits) h.song];
    final ok = await resolveAndPlay(ref, hit.song, queue: queue);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('「${hit.song.title}」暂无法播放（可能需要登录或受版权限制）'),
      ));
    }
  }

  void _openPlaylist(Playlist playlist) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaylistDetailPage(playlist: playlist),
    ));
  }

  void _openArtist(Artist artist) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ArtistPage(artist: artist)));
  }

  void _openAlbum(Album album) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => AlbumPage(album: album)));
  }

  bool get _isTabLoading => _loading.contains(_tab);
  String? get _tabError => _errors[_tab];

  int get _tabCount {
    switch (_tab) {
      case 0:
        return _songs.length;
      case 1:
        return _playlists.length;
      case 2:
        return _artists.length;
      case 3:
        return _albums.length;
      case 4:
        return _lyricHits.length;
    }
    return 0;
  }

  String get _tabCountText {
    switch (_tab) {
      case 0:
        return '「$_keyword」· 去重后 ${_songs.length} 首';
      case 1:
        return '「$_keyword」· ${_playlists.length} 个歌单';
      case 2:
        return '「$_keyword」· ${_artists.length} 位歌手';
      case 3:
        return '「$_keyword」· ${_albums.length} 张专辑';
      case 4:
        return '「$_keyword」· ${_lyricHits.length} 条歌词';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return Column(
      children: [
        Padding(
          // 顶部安全区由壳层 MobilePageSafeArea 统一避让（手机端为 0）；
          // 桌面端保持原来的 16dp，桌面布局零变化。
          padding: EdgeInsets.fromLTRB(
            16,
            jxPageTopInset(context, desktop: 16),
            16,
            8,
          ),
          child: GlassCard(
            borderRadius: BorderRadius.circular(30),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 46,
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.search,
                onSubmitted: _search,
                textAlignVertical: TextAlignVertical.center,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '搜索歌曲 / 歌单 / 歌手 / 专辑 / 歌词（三平台聚合）',
                  hintStyle: const TextStyle(fontSize: 14, height: 1.2),
                  prefixIcon: const Icon(Icons.search_rounded,
                      size: 22, color: JXColors.primary),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 34, minHeight: 34),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 20),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    onPressed: () {
                      _controller.clear();
                      setState(() {
                        _searched = false;
                        _keyword = '';
                        _loaded.clear();
                        _loading.clear();
                        _errors.clear();
                        _songs = const [];
                        _playlists = const [];
                        _artists = const [];
                        _albums = const [];
                        _lyricHits = const [];
                        _rawSongCount = 0;
                      });
                    },
                  ),
                  suffixIconConstraints:
                      const BoxConstraints(minWidth: 34, minHeight: 34),
                ),
                style: const TextStyle(fontSize: 14, height: 1.2),
              ),
            ),
          ),
        ),
        // 模块 tab
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              for (var i = 0; i < _tabNames.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(left: i > 0 ? 6 : 0),
                    child: _buildTabPill(i, isDark, textColor),
                  ),
                ),
            ],
          ),
        ),
        if (_searched && !_isTabLoading && _tabCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Row(
              children: [
                // 关键词是任意用户输入，长词会撑爆 360dp 宽的 Row，需可收缩省略
                Flexible(
                  child: Text(
                    _tabCountText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: textSub),
                  ),
                ),
                if (_tab == 0 && _rawSongCount > _songs.length) ...[
                  const SizedBox(width: 6),
                  Text(
                    '（合并 $_rawSongCount 条音源）',
                    style: TextStyle(fontSize: 11, color: textSub),
                  ),
                ],
              ],
            ),
          ),
        Expanded(
          child: !_searched
              ? _SearchHints(onTap: (kw) {
                  _controller.text = kw;
                  _search(kw);
                })
              : _isTabLoading
                  ? const Center(
                      child:
                          CircularProgressIndicator(color: JXColors.primary))
                  : _tabError != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _tabError!,
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(fontSize: 13, color: textSub),
                            ),
                          ),
                        )
                      : _buildTabContent(),
        ),
      ],
    );
  }

  /// 模块切换 pill：选中填主题色，未选中走液态玻璃表面
  Widget _buildTabPill(int i, bool isDark, Color textColor) {
    final selected = i == _tab;
    return GestureDetector(
      onTap: () => _switchTab(i),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? JXColors.primary
              : (isDark ? JXColors.glassDark : JXColors.glassLight)
                  .withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : isDark
                    ? JXColors.glassStrokeDark
                    : JXColors.glassStrokeLight,
          ),
        ),
        child: Text(
          _tabNames[i],
          maxLines: 1,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : textColor,
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_tab) {
      case 0:
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: _songs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final g = _songs[i];
            return _TrackGroupRow(
              group: g,
              index: i,
              onTap: () => _play(g),
              onPlaySource: (source) => _play(g, preferred: source),
            );
          },
        );
      case 1:
        return _PlaylistGrid(playlists: _playlists, onTap: _openPlaylist);
      case 2:
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: _artists.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _ArtistRow(
            artist: _artists[i],
            index: i,
            onTap: () => _openArtist(_artists[i]),
          ),
        );
      case 3:
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: _albums.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _AlbumRow(
            album: _albums[i],
            index: i,
            onTap: () => _openAlbum(_albums[i]),
          ),
        );
      case 4:
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: _lyricHits.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _LyricRow(
            hit: _lyricHits[i],
            index: i,
            onTap: () => _playLyricHit(_lyricHits[i]),
          ),
        );
    }
    return const SizedBox.shrink();
  }
}

/// 歌单结果网格：复用首页/全部歌单的 JXPlaylistCard（封面 + 平台角标）
class _PlaylistGrid extends StatelessWidget {
  final List<Playlist> playlists;
  final void Function(Playlist) onTap;

  const _PlaylistGrid({required this.playlists, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      // 3~6 列自适应：手机 3 列，宽屏最多 6 列
      final crossCount =
          ((width + 12) / 130).floor().clamp(3, 6);
      const spacing = 12.0;
      final tileW = (width - spacing * (crossCount - 1)) / crossCount;
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossCount,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 14,
          // 卡片高 = 封面 + 标题行（JXPlaylistCard 内部结构固定）
          mainAxisExtent: tileW + 26,
        ),
        itemCount: playlists.length,
        itemBuilder: (context, i) => JXPlaylistCard(
          playlist: playlists[i],
          width: tileW,
          gradientIndex: i,
          onTap: onTap,
        ),
      );
    });
  }
}

/// 歌手结果行：圆形头像 + 名称 + 歌曲数/专辑数 + 平台标签
class _ArtistRow extends StatelessWidget {
  final Artist artist;
  final int index;
  final VoidCallback onTap;

  const _ArtistRow({
    required this.artist,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    final parts = <String>[
      if (artist.songCount > 0) '歌曲 ${artist.songCount}',
      if (artist.albumCount > 0) '专辑 ${artist.albumCount}',
    ];
    final sub = parts.isEmpty
        ? JXPlaylistCard.platformShort(artist.platform)
        : parts.join(' · ');

    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Row(
        children: [
          JXCover(
            url: artist.avatarUrl,
            size: 48,
            radius: 24,
            gradientIndex: index,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  artist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: textSub),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _PlatformTag(platform: artist.platform),
          GlassIconButton(
            icon: Icons.chevron_right_rounded,
            size: 30,
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

/// 专辑结果行：封面 + 专辑名 + 歌手/发行时间/曲目数 + 平台标签
class _AlbumRow extends StatelessWidget {
  final Album album;
  final int index;
  final VoidCallback onTap;

  const _AlbumRow({
    required this.album,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    final parts = <String>[
      if (album.artist.trim().isNotEmpty) album.artist.trim(),
      if (album.publishTime.trim().isNotEmpty) album.publishTime.trim(),
      if (album.songCount > 0) '${album.songCount} 首',
    ];
    final sub = parts.isEmpty
        ? JXPlaylistCard.platformShort(album.platform)
        : parts.join(' · ');

    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Row(
        children: [
          JXCover(
            url: album.coverUrl,
            size: 50,
            radius: 14,
            gradientIndex: index,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  album.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: textSub),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _PlatformTag(platform: album.platform),
          GlassIconButton(
            icon: Icons.chevron_right_rounded,
            size: 30,
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

/// 歌词命中行：封面 + 歌名/歌手 + 命中歌词片段 + 播放按钮
class _LyricRow extends StatelessWidget {
  final LyricHit hit;
  final int index;
  final VoidCallback onTap;

  const _LyricRow({
    required this.hit,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    final song = hit.song;

    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Row(
        children: [
          JXCover(
            url: song.coverUrl,
            size: 44,
            radius: 12,
            gradientIndex: index,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: textColor,
                        ),
                      ),
                    ),
                    if (song.vip) ...[
                      const SizedBox(width: 6),
                      const Text(
                        'VIP',
                        style: TextStyle(
                            fontSize: 9.5,
                            color: JXColors.accentPink,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: textSub),
                ),
                if (hit.snippet.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    hit.snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: textSub, height: 1.3),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          _PlatformTag(platform: song.platform),
          const SizedBox(width: 4),
          GlassIconButton(
            icon: Icons.play_arrow_rounded,
            size: 34,
            color: JXColors.primary,
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

/// 平台小标签：色点 + 平台短名（歌单/歌手/专辑/歌词行共用）
class _PlatformTag extends StatelessWidget {
  final int platform;

  const _PlatformTag({required this.platform});

  @override
  Widget build(BuildContext context) {
    final color = JXPlatform.color(platform);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 3),
          Text(
            _SourceChip.shortName(platform),
            style: TextStyle(
              fontSize: 9.5,
              color: color.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索结果行：一首歌一行；音源标签标出「首选」，点标签可直接用该平台播放
class _TrackGroupRow extends StatelessWidget {
  final TrackGroup group;
  final int index;
  final VoidCallback onTap;
  final void Function(Song source) onPlaySource;

  const _TrackGroupRow({
    required this.group,
    required this.index,
    required this.onTap,
    required this.onPlaySource,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Row(
        children: [
          JXCover(
            url: group.coverUrl,
            size: 46,
            radius: 12,
            gradientIndex: index,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        group.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: textColor,
                        ),
                      ),
                    ),
                    if (group.allVip) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color:
                              JXColors.accentPink.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('VIP',
                            style: TextStyle(
                                fontSize: 9.5,
                                color: JXColors.accentPink,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  group.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: textSub),
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    for (final s in group.orderedSources)
                      _SourceChip(
                        source: s,
                        selected: s.globalId == group.primary.globalId,
                        onTap: () => onPlaySource(s),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          GlassIconButton(
            icon: Icons.play_arrow_rounded,
            size: 36,
            color: JXColors.primary,
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

/// 音源平台小标签：「首选·XX」表示点整行时播放的就是这个平台；点标签可直接切平台
class _SourceChip extends StatelessWidget {
  final Song source;
  final bool selected;
  final VoidCallback onTap;

  const _SourceChip({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  static String shortName(int platform) {
    switch (platform) {
      case JXPlatform.qq:
        return 'QQ';
      case JXPlatform.netease:
        return '网易云';
      case JXPlatform.kugou:
        return '酷狗';
      default:
        return '本地';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = JXPlatform.color(source.platform);
    final label =
        '${selected ? '首选·' : ''}${shortName(source.platform)}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 0.22 : 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                selected ? color.withValues(alpha: 0.7) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 9.5,
                color: selected ? color : color.withValues(alpha: 0.85),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
            if (source.vip) ...[
              const SizedBox(width: 3),
              const Text(
                'VIP',
                style: TextStyle(
                    fontSize: 8,
                    color: JXColors.accentPink,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 搜索建议（未搜索时）
class _SearchHints extends StatelessWidget {
  final void Function(String) onTap;

  const _SearchHints({required this.onTap});

  static const _keywords = [
    '周杰伦',
    '陈奕迅',
    '林俊杰',
    '民谣',
    '治愈',
    '电子',
    '摇滚',
    '粤语',
    '时间煮雨',
    '卡农',
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Text('试试搜索',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textSub)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kw in _keywords)
              GestureDetector(
                onTap: () => onTap(kw),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: (isDark
                            ? JXColors.glassDark
                            : JXColors.glassLight)
                        .withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark
                          ? JXColors.glassStrokeDark
                          : JXColors.glassStrokeLight,
                    ),
                  ),
                  child: Text(kw, style: const TextStyle(fontSize: 12.5)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
