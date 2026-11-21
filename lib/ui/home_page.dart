import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../providers.dart';
import '../services/guess_you_like.dart';
import '../services/playback.dart';
import 'glass.dart';
import 'playlist_detail_page.dart';
import 'playlist_hub_page.dart';
import 'playlist_row.dart';
import 'layout.dart';

/// 首页（双端独立布局）：
/// - 桌面版：今日推荐 banner + 三平台聚合推荐歌单 + 聚合热门单曲列表
/// - 手机版：标题 + 搜索框 + 紧凑 banner + 聚合横滑歌单 + 三平台聚合热歌榜（响应式）
///
/// 「聚合」= QQ / 网易云 / 酷狗按轮询交错合并（QQ#1、网易云#1、酷狗#1、QQ#2…），
/// 歌单卡片自带平台角标、歌曲行带平台色点，各平台数据一目了然。
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

  /// 热歌榜（手机版）/ 热门单曲（桌面版）是否内联展开：点击「更多 ›」不再
  /// 重新加载整个首页，而是把该平台已缓存的全部 topSongs 展开显示，按钮变「收起 ›」。
  bool _rankExpanded = false;
  bool _hotExpanded = false;

  /// 分平台推荐歌单：0=QQ、1=网易云、2=酷狗
  final Map<int, List<Playlist>> _playlistsByPlatform = {};

  /// 猜你喜欢：口味候选池（按口味歌手跨平台搜索、排除已听、去重）。
  /// 展示取样见 [_guessPicks]（每日种子 + 「换一批」批次）。
  final List<Song> _guessPool = [];
  int _guessBatch = 0;

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

    // 三平台推荐歌单：各拉一个较大的推荐池（30 个），每次刷新随机截取
    // 其中 10 个（随机窗口，窗口内保持平台排序）。平台推荐池本身每日
    // 更新，随机窗口保证每次刷新都可能刷出新歌单。
    futures.add(() async {
      for (final p in const [
        JXPlatform.qq,
        JXPlatform.netease,
        JXPlatform.kugou,
      ]) {
        final api = hub.api(p);
        if (api == null) continue;
        try {
          final list = await api.recommendPlaylists(size: 30);
          if (mounted) {
            setState(
                () => _playlistsByPlatform[p] = _randomWindow(list, 10));
          }
        } catch (_) {
          if (mounted) {
            setState(() => _playlistsByPlatform[p] = const []);
          }
        }
      }
    }());

    // 猜你喜欢：从播放历史/收藏派生口味歌手，按歌手轮换平台搜索候选池
    // （排除已听过的歌、去重）。无历史时候选池为空，区块整体隐藏。
    // 整体 try/catch：口味推荐是增强功能，曲库/搜索失败时静默隐藏，
    // 绝不影响首页主内容（榜单/歌单）的加载与展示。
    futures.add(() async {
      try {
        final library = ref.read(libraryProvider);
        final artists =
            GuessYouLike.tasteArtists(library.history, library.favorites);
        if (artists.isEmpty) {
          if (mounted) setState(_guessPool.clear);
          return;
        }
        final heard = <String>{
          for (final entry in library.history) entry.song.globalId,
          for (final song in library.favorites) song.globalId,
        };
        final pool = <Song>[];
        final seen = <String>{};
        const rotation = [JXPlatform.qq, JXPlatform.netease, JXPlatform.kugou];
        for (var i = 0; i < artists.length; i++) {
          final api = hub.api(rotation[i % rotation.length]);
          if (api == null) continue;
          try {
            for (final song in await api.searchSongs(artists[i], size: 15)) {
              if (heard.contains(song.globalId)) continue;
              if (seen.add(song.globalId)) pool.add(song);
            }
          } catch (_) {}
        }
        if (mounted) {
          setState(() {
            _guessPool
              ..clear()
              ..addAll(pool);
          });
        }
      } catch (_) {}
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

  /// 「全部歌单 · 三平台」聚合页（顶部平台 pill 切换各平台分页歌单）
  void _openPlaylistHub() {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PlaylistHubPage()));
  }

  /// 从列表中随机截取最多 [take] 个元素的连续窗口（窗口内保持原顺序）。
  /// 用于「刷新随机出新歌单」：池子小于 take 时原样返回。
  static List<T> _randomWindow<T>(List<T> list, int take) {
    if (list.length <= take) return list;
    final start = Random().nextInt(list.length - take + 1);
    return list.sublist(start, start + take);
  }

  /// 多列表轮询交错合并：[A1,B1,C1,A2,B2,C2,…]，长度不齐时短的自动跳过。
  /// 用于三平台歌单 / 热歌的「聚合」展示，保证任何平台接口缺数据时其余
  /// 平台的内容仍按原顺序补位。
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

  /// 三平台推荐歌单聚合（轮询交错，卡片自带平台角标）
  List<Playlist> _mergedPlaylists() => _interleave<Playlist>([
        for (final p in const [JXPlatform.qq, JXPlatform.netease, JXPlatform.kugou])
          _playlistsByPlatform[p] ?? const <Playlist>[],
      ]);

  /// 三平台热歌聚合（轮询交错，顺序 = QQ、网易云、酷狗）
  List<Song> _mergedTopSongs() => _interleave<Song>([
        for (final p in const [JXPlatform.qq, JXPlatform.netease, JXPlatform.kugou])
          _tops[p] ?? const <Song>[],
      ]);

  /// 猜你喜欢当日取样：种子 = 日期种子 ×1000 + 「换一批」批次。
  /// 同一天同一批结果稳定；点「换一批」批次 +1 从候选池换一批新歌。
  List<Song> _guessPicks() =>
      GuessYouLike.picks(_guessPool, DateTime.now(), _guessBatch);

  /// 桌面版「猜你喜欢」歌曲行列表（历史口味派生 + 每日种子取样）
  List<Widget> _guessRows() {
    final songs = _guessPicks();
    return [
      for (var i = 0; i < songs.length; i++)
        SongRow(
          title: songs[i].title,
          artist: songs[i].artist,
          tag: JXPlatform.name(songs[i].platform),
          tagColor: JXPlatform.color(songs[i].platform),
          durationText: jxFormatDuration(songs[i].duration),
          coverUrl: songs[i].coverUrl,
          gradientIndex: i,
          onTap: () => _resolveAndPlay(songs[i], queue: songs),
        ),
    ];
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
          // 三平台聚合推荐歌单（轮询交错，卡片自带平台角标；「更多」进
          // 全部歌单聚合页，可按平台切换分页浏览）
          SliverToBoxAdapter(
            child: JXSectionHeader(
              title: '推荐歌单 · 三平台聚合',
              onMore: _openPlaylistHub,
            ),
          ),
          SliverToBoxAdapter(
            child: JXPlaylistRow(
              playlists: _mergedPlaylists(),
              cardWidth: 176,
              onTap: _openPlaylist,
            ),
          ),
          // 猜你喜欢（历史口味派生，每日种子稳定；「换一批」批次 +1 换新歌）
          if (_guessPicks().isNotEmpty) ...[
            SliverToBoxAdapter(
              child: JXSectionHeader(
                title: '猜你喜欢',
                moreText: '换一批 ›',
                onMore: () => setState(() => _guessBatch++),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: _guessRows(),
                ),
              ),
            ),
          ],
          // 热门单曲（三平台轮询交错聚合）：默认每平台 3 首共 9 首，
          // 点「更多 ›」内联展开全部已加载歌曲
          SliverToBoxAdapter(
            child: JXSectionHeader(
              title: '热门单曲',
              moreText: _hotExpanded ? '收起 ›' : '更多 ›',
              onMore: () => setState(() => _hotExpanded = !_hotExpanded),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: _hotRows(),
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
    final cardW = (w * 0.30).clamp(100.0, 140.0); // 360~400 双列 / >400 放大
    final collapsedRankRows = w < 400 ? 6 : 9; // 聚合卡折叠：每平台 2/3 首
    final mergedTops = _mergedTopSongs();

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
          // 三平台聚合推荐歌单（轮询交错，卡片自带平台角标）
          SliverToBoxAdapter(
            child: JXSectionHeader(
                title: '推荐歌单 · 三平台聚合',
                paddingLeft: 16,
                onMore: _openPlaylistHub),
          ),
          SliverToBoxAdapter(
            child: JXPlaylistRow(
              playlists: _mergedPlaylists(),
              cardWidth: cardW,
              onTap: _openPlaylist,
            ),
          ),
          // 猜你喜欢（历史口味派生，每日种子稳定；「换一批」批次 +1 换新歌）
          if (_guessPicks().isNotEmpty) ...[
            SliverToBoxAdapter(
              child: JXSectionHeader(
                  title: '猜你喜欢',
                  paddingLeft: 16,
                  moreText: '换一批 ›',
                  onMore: () => setState(() => _guessBatch++)),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child:               _AggRankCard(
                  title: '根据你的口味每日推荐',
                  songs: _guessPicks(),
                  onPlay: (s) => _resolveAndPlay(s, queue: _guessPicks()),
                  maxRows: _guessPicks().length,
                ),
              ),
            ),
          ],
          // 热歌榜（三平台轮询交错聚合）：默认 6 行（每平台 2 首），
          // 点「更多 ›」内联展开全部已加载歌曲（不重新请求网络）
          SliverToBoxAdapter(
            child: JXSectionHeader(
                title: '热歌榜',
                paddingLeft: 16,
                moreText: _rankExpanded ? '收起 ›' : '更多 ›',
                onMore: () =>
                    setState(() => _rankExpanded = !_rankExpanded)),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: mergedTops.isEmpty
                  ? const SizedBox(height: 40)
                  : _AggRankCard(
                      songs: mergedTops,
                      onPlay: (s) => _resolveAndPlay(s, queue: mergedTops),
                      maxRows: _rankExpanded
                          ? mergedTops.length
                          : collapsedRankRows,
                    ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ],
    );
  }

  /// 桌面版「热门单曲」聚合行：三平台轮询交错，默认每平台 3 首共 9 首，
  /// 点「更多 ›」展开后显示全部已加载歌曲（来自 _tops 缓存，不重新请求网络）。
  List<Widget> _hotRows() {
    final songs = _mergedTopSongs();
    final limit = _hotExpanded
        ? songs.length
        : (songs.length > 9 ? 9 : songs.length);
    return [
      for (var i = 0; i < limit; i++)
        SongRow(
          title: songs[i].title,
          artist: songs[i].artist,
          tag: JXPlatform.name(songs[i].platform),
          tagColor: JXPlatform.color(songs[i].platform),
          durationText: jxFormatDuration(songs[i].duration),
          coverUrl: songs[i].coverUrl,
          gradientIndex: i,
          onTap: () => _resolveAndPlay(songs[i], queue: songs),
        ),
    ];
  }

  Future<void> _playTop() async {
    for (final p in const [0, 1, 2]) {
      final songs = _tops[p];
      if (songs != null && songs.isNotEmpty) {
        await _resolveAndPlay(songs.first, queue: songs);
        return;
      }
    }
  }

  Future<void> _resolveAndPlay(Song song, {List<Song>? queue}) async {
    final ok = await resolveAndPlay(ref, song, queue: queue);
    if (ok || !mounted) return;
    jxShowNotice(
        context,
        '「${song.title}」暂时无法播放：三个平台都没有可用的免费版本，'
        '可能需要登录对应平台或受版权限制');
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
      // 顶部安全区由壳层 MobilePageSafeArea 统一避让，这里只保留水平内边距
      // （原来硬编码 top=14 会与安全区叠加成双重留白）。
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
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

/// 手机版三平台聚合热歌榜卡片：轮询交错的合并榜单（合并序号 1..N），
/// 每行带平台色点 + 平台短名，行数由 [maxRows] 控制（折叠/展开）。
/// [title] 用于复用卡片头部文案（热歌榜 / 猜你喜欢）。
class _AggRankCard extends StatelessWidget {
  final List<Song> songs;
  final void Function(Song) onPlay;
  final int maxRows;
  final String title;

  const _AggRankCard({
    required this.songs,
    required this.onPlay,
    required this.maxRows,
    this.title = '三平台热歌聚合',
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
              // 三平台色点并排：聚合榜的来源标识
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: JXPlatform.color(const [0, 1, 2][i]),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
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
              // opaque：整行（含文字旁留白/间隙）都响应点击播放
              behavior: HitTestBehavior.opaque,
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
                    // 平台色点 + 短名（QQ / 网易云 / 酷狗）
                    SizedBox(
                      width: 38,
                      child: Row(
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: JXPlatform.color(songs[i].platform),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              JXPlaylistCard.platformShort(songs[i].platform),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                  color: JXPlatform.color(songs[i].platform)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
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

