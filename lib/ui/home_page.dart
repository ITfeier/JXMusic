import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../providers.dart';
import '../services/playback.dart';
import 'glass.dart';
import 'playlist_detail_page.dart';
import 'playlist_list_page.dart';
import 'playlist_row.dart';
import 'layout.dart';

/// 首页（双端独立布局）：
/// - 桌面版：今日推荐 banner + 推荐歌单多列网格 + 热门单曲列表
/// - 手机版：标题 + 搜索框 + 紧凑 banner + 横滑歌单 + 双列热歌榜（响应式）
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  // 初值必须是 false：initState 里的 _load() 会被 `if (_loading) return;`
  // 守卫拦住，若初值为 true 则首次加载永远不发起（0.9.3 引入的首页永久转圈 bug）。
  bool _loading = false;
  final Map<int, List<Song>> _tops = {};

  /// 分平台推荐歌单：0=QQ、1=网易云、2=酷狗
  final Map<int, List<Playlist>> _playlistsByPlatform = {};

  DateTime? _lastLoaded;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final hub = ref.read(musicHubProvider);

    // 并行拉取三平台榜单
    final futures = <Future<void>>[
      for (final p in const [0, 1, 2])
        () async {
          final api = hub.api(p);
          if (api == null) return;
          final songs = await api.topSongs(size: 20);
          if (mounted) setState(() => _tops[p] = songs);
        }(),
    ];

    // 三平台推荐歌单各自拉取（分平台展示，互不影响）
    futures.add(() async {
      for (final p in const [
        JXPlatform.qq,
        JXPlatform.netease,
        JXPlatform.kugou,
      ]) {
        final api = hub.api(p);
        if (api == null) continue;
        try {
          final list = await api.recommendPlaylists(size: 10);
          if (mounted) {
            setState(() => _playlistsByPlatform[p] = list);
          }
        } catch (_) {
          if (mounted) {
            setState(() => _playlistsByPlatform[p] = const []);
          }
        }
      }
    }());

    try {
      await Future.wait(futures);
    } catch (e) {
      if (mounted) setState(() => _error = '数据加载失败：$e');
    }
    if (mounted) {
      setState(() => _loading = false);
      _lastLoaded = DateTime.now();
    }
  }

  /// 从歌单卡片进入详情
  void _openPlaylist(Playlist playlist) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaylistDetailPage(playlist: playlist),
    ));
  }

  /// 该平台「全部歌单」页（分页网格；替代旧版「换一批」）
  void _openAllPlaylists(int platform) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaylistListPage(platform: platform),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // 切回首页且距上次加载超过 1 分钟时自动刷新（保证歌单/榜单不是陈旧数据）
    ref.listen<int>(navIndexProvider, (previous, next) {
      if (next == 0 && !_loading) {
        final last = _lastLoaded;
        if (last == null || DateTime.now().difference(last).inMinutes >= 1) {
          _load();
        }
      }
    });
    return isDesktopLayout(context)
        ? _buildDesktop(context)
        : _buildMobile(context);
  }

  // ---------------- 桌面版 ----------------
  Widget _buildDesktop(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: JXBanner(onPlay: () => _playTop()),
          ),
        ),
        if (_loading)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: CircularProgressIndicator(color: JXColors.primary),
            ),
          )
        else ...[
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: GlassCard(
                  child: Column(
                    children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      GlassButton(text: '重试', onPressed: _load),
                    ],
                  ),
                ),
              ),
            ),
          // 分平台推荐歌单（三平台各自展示；「更多」进入该平台全部歌单页，
          // 回首页超 60s 自动刷新）
          for (final platform in const [0, 1, 2]) ...[
            SliverToBoxAdapter(
              child: JXSectionHeader(
                title: '${JXPlatform.name(platform)} · 推荐歌单',
                onMore: () => _openAllPlaylists(platform),
              ),
            ),
            SliverToBoxAdapter(
              child: JXPlaylistRow(
                playlists: _playlistsByPlatform[platform] ?? const [],
                cardWidth: 176,
                onTap: _openPlaylist,
              ),
            ),
          ],          // 热门单曲
          SliverToBoxAdapter(
            child: JXSectionHeader(title: '热门单曲', onMore: _load),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  for (final platform in const [0, 1, 2])
                    for (var i = 0;
                        i < (_tops[platform]?.length ?? 0) && i < 3;
                        i++)
                      SongRow(
                        title: _tops[platform]![i].title,
                        artist: _tops[platform]![i].artist,
                        tag: JXPlatform.name(platform),
                        tagColor: JXPlatform.color(platform),
                        durationText:
                            jxFormatDuration(_tops[platform]![i].duration),
                        coverUrl: _tops[platform]![i].coverUrl,
                        gradientIndex: i,
                        onTap: () => _resolveAndPlay(_tops[platform]![i]),
                      ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 30)),
        ],
      ],
    );
  }

  // ---------------- 手机版 ----------------
  Widget _buildMobile(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final singleCol = w < 360; // <360dp：单列大图
    final cardW = (w * 0.30).clamp(100.0, 140.0); // 360~400 双列 / >400 放大
    final rankRows = w < 400 ? 3 : 4; // >400dp 信息密度提升

    // 前两个有数据的平台榜单
    final plats = <int>[
      for (final p in const [0, 1, 2])
        if (_tops[p]?.isNotEmpty ?? false) p
    ];

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _MobileHeader(
            onRefresh: _load,
            onSearch: () =>
                ref.read(navIndexProvider.notifier).state = 1,
          ),
        ),
        if (_loading)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: CircularProgressIndicator(color: JXColors.primary),
            ),
          )
        else ...[
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: GlassCard(
                  child: Column(
                    children: [
                      Text(_error!, style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 10),
                      GlassButton(text: '重试', onPressed: _load),
                    ],
                  ),
                ),
              ),
            ),
          // banner
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: JXBanner(compact: true, onPlay: () => _playTop()),
            ),
          ),
          // 分平台推荐歌单（横滑卡片，宽度随屏宽缩放；「更多」进入全部歌单页）
          for (final platform in const [0, 1, 2]) ...[
            SliverToBoxAdapter(
              child: JXSectionHeader(
                  title: '${JXPlatform.name(platform)} · 推荐歌单',
                  paddingLeft: 16,
                  onMore: () => _openAllPlaylists(platform)),
            ),
            SliverToBoxAdapter(
              child: JXPlaylistRow(
                playlists: _playlistsByPlatform[platform] ?? const [],
                cardWidth: cardW,
                onTap: _openPlaylist,
              ),
            ),
          ],          // 热歌榜
          SliverToBoxAdapter(
            child: JXSectionHeader(
                title: '热歌榜', paddingLeft: 16, onMore: _load),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: plats.isEmpty
                  ? const SizedBox(height: 40)
                  : singleCol || plats.length == 1
                      ? _RankCard(
                          platform: plats[0],
                          songs: _tops[plats[0]]!,
                          onPlay: (s) => _resolveAndPlay(s),
                          maxRows: rankRows,
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _RankCard(
                                platform: plats[0],
                                songs: _tops[plats[0]]!,
                                onPlay: (s) => _resolveAndPlay(s),
                                maxRows: rankRows,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _RankCard(
                                platform: plats[1],
                                songs: _tops[plats[1]]!,
                                onPlay: (s) => _resolveAndPlay(s),
                                maxRows: rankRows,
                              ),
                            ),
                          ],
                        ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ],
    );
  }

  Future<void> _playTop() async {
    for (final p in const [0, 1, 2]) {
      final songs = _tops[p];
      if (songs != null && songs.isNotEmpty) {
        await _resolveAndPlay(songs.first);
        return;
      }
    }
  }

  Future<void> _resolveAndPlay(Song song) async {
    final ok = await resolveAndPlay(ref, song);
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          '「${song.title}」暂时无法播放：三个平台都没有可用的免费版本，可能需要登录对应平台或受版权限制'),
    ));
  }
}

/// 手机版首页头部：标题 + 搜索框（点击跳搜索页）
class _MobileHeader extends StatelessWidget {
  final VoidCallback onRefresh;
  final VoidCallback onSearch;

  const _MobileHeader({required this.onRefresh, required this.onSearch});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '首页',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: textColor),
              ),
              const Spacer(),
              GlassIconButton(
                icon: Icons.refresh_rounded,
                size: 36,
                onPressed: onRefresh,
              ),
            ],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onSearch,
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: (isDark ? JXColors.glassDark : JXColors.glassLight)
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(21),
                border: Border.all(
                  color: isDark
                      ? JXColors.glassStrokeDark
                      : JXColors.glassStrokeLight,
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded,
                      size: 19, color: JXColors.primary),
                  const SizedBox(width: 8),
                  Text('搜索歌曲 / 歌手 / 专辑',
                      style: TextStyle(fontSize: 12.5, color: textSub)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 手机版热歌榜卡片（双列并排 / 窄屏单列大图）
class _RankCard extends StatelessWidget {
  final int platform;
  final List<Song> songs;
  final void Function(Song) onPlay;
  final int maxRows;

  const _RankCard({
    required this.platform,
    required this.songs,
    required this.onPlay,
    required this.maxRows,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      borderRadius: BorderRadius.circular(20),
      margin: const EdgeInsets.only(bottom: 14),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: JXPlatform.color(platform),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${JXPlatform.name(platform)} · 热榜',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              GestureDetector(
                onTap: () => onPlay(songs.first),
                child: const Icon(Icons.play_circle_fill_rounded,
                    color: JXColors.primary, size: 24),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < (songs.length > maxRows ? maxRows : songs.length);
              i++)
            GestureDetector(
              onTap: () => onPlay(songs[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: i < 3 ? JXColors.accentPink : textSub,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            songs[i].title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: textColor,
                                fontWeight: FontWeight.w500),
                          ),
                          Text(
                            songs[i].artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: textSub),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.play_arrow_rounded,
                        color: textSub, size: 18),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

