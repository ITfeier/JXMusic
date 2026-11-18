import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/playlist.dart';
import '../providers.dart';
import 'glass.dart';
import 'playlist_detail_page.dart';
import 'playlist_row.dart';

/// 某平台的「全部歌单」页。
///
/// 首页每个平台区块右侧「更多」进入这里（替代旧版「换一批」逻辑：
/// 旧逻辑只是把首页 10 条换成下一批，用户看不到"更多歌单"）。
///
/// - 网格展示：卡片视觉复用 [JXPlaylistCard]（封面 + 平台/曲目数角标 + 单行标题）；
/// - 分页：首屏 page=1 / size=20，滑到底自动加载下一页，底部提示「加载中 / 没有更多了」；
/// - 空态与失败态均提供「重试」；点卡片进入 [PlaylistDetailPage]。
///
/// 三个平台的分页口径由各自 API 适配（QQ sin/ein、网易云 offset、酷狗 page），
/// 这里只依赖 `recommendPlaylists(page:size:)` 的抽象。
class PlaylistListPage extends ConsumerStatefulWidget {
  final int platform;

  /// 内嵌在 [PlaylistHubPage] 里时隐藏返回按钮（由外层页面统一返回）。
  final bool showBack;

  const PlaylistListPage({super.key, required this.platform, this.showBack = true});

  @override
  ConsumerState<PlaylistListPage> createState() => _PlaylistListPageState();
}

class _PlaylistListPageState extends ConsumerState<PlaylistListPage> {
  static const int _pageSize = 20;
  static const double _hPadding = 16;
  static const double _crossSpacing = 12;

  final ScrollController _scroll = ScrollController();
  final List<Playlist> _playlists = [];

  int _page = 1;
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error; // 首屏失败
  String? _moreError; // 加载更多失败

  /// 请求序号：刷新/重试时丢弃仍在途的旧响应，避免数据串页
  int _requestSeq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadFirst();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  String get _title => '${JXPlatform.name(widget.platform)} · 全部歌单';

  Future<List<Playlist>> _fetchPage(int page) async {
    final api = ref.read(musicHubProvider).api(widget.platform);
    if (api == null) throw StateError('该平台暂不支持歌单');
    return api.recommendPlaylists(page: page, size: _pageSize);
  }

  Future<void> _loadFirst() async {
    final seq = ++_requestSeq;
    setState(() {
      _initialLoading = true;
      _loadingMore = false;
      _error = null;
      _moreError = null;
      _hasMore = true;
      _page = 1;
      _playlists.clear();
    });
    try {
      final list = await _fetchPage(1);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _playlists.addAll(list);
        _hasMore = list.length >= _pageSize;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() => _error = '加载失败：$e');
    } finally {
      if (mounted && seq == _requestSeq) {
        setState(() => _initialLoading = false);
      }
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_initialLoading || _loadingMore || !_hasMore || _moreError != null) {
      return;
    }
    final seq = _requestSeq;
    setState(() => _loadingMore = true);
    final nextPage = _page + 1;
    try {
      final list = await _fetchPage(nextPage);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _page = nextPage;
        final seen = _playlists.map((p) => '${p.platform}:${p.id}').toSet();
        for (final p in list) {
          if (seen.add('${p.platform}:${p.id}')) _playlists.add(p);
        }
        _hasMore = list.length >= _pageSize;
        _moreError = null;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() => _moreError = '加载更多失败：$e');
    } finally {
      if (mounted && seq == _requestSeq) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _retryMore() {
    if (_loadingMore) return;
    setState(() => _moreError = null);
    _loadMore();
  }

  void _openDetail(Playlist playlist) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaylistDetailPage(playlist: playlist),
    ));
  }

  /// 列数：桌面 4~6 列、手机 2~3 列，按可用宽度自适应
  int _columnsFor(double width) {
    if (width >= 840) return (width / 240).floor().clamp(4, 6);
    return width < 380 ? 2 : 3;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
              _buildHeader(context, isDark),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (_initialLoading) {
                      return const Center(
                        child: CircularProgressIndicator(
                            color: JXColors.primary),
                      );
                    }
                    if (_error != null) {
                      return _MessageView(
                        icon: Icons.cloud_off_rounded,
                        title: _error!,
                        actionText: '重试',
                        onAction: _loadFirst,
                      );
                    }
                    if (_playlists.isEmpty) {
                      return _MessageView(
                        icon: Icons.queue_music_rounded,
                        title: '暂无歌单',
                        subtitle: '平台接口可能临时不可用，请稍后重试',
                        actionText: '重试',
                        onAction: _loadFirst,
                      );
                    }
                    final columns = _columnsFor(constraints.maxWidth);
                    final gridWidth =
                        constraints.maxWidth - _hPadding * 2;
                    final cardWidth = (gridWidth -
                            _crossSpacing * (columns - 1)) /
                        columns;
                    return CustomScrollView(
                      controller: _scroll,
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(
                              _hPadding, 4, _hPadding, 8),
                          sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              crossAxisSpacing: _crossSpacing,
                              mainAxisSpacing: 16,
                              mainAxisExtent: cardWidth + 30,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, i) {
                                final p = _playlists[i];
                                return JXPlaylistCard(
                                  playlist: p,
                                  width: cardWidth,
                                  gradientIndex: i,
                                  onTap: _openDetail,
                                );
                              },
                              childCount: _playlists.length,
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(child: _buildFooter(isDark)),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        children: [
          if (widget.showBack) ...[
            GlassIconButton(
              icon: Icons.arrow_back_rounded,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: textColor),
                ),
                if (!_initialLoading &&
                    _error == null &&
                    _playlists.isNotEmpty)
                  Text(
                    '已加载 ${_playlists.length} 个',
                    style: TextStyle(fontSize: 11, color: textSub),
                  ),
              ],
            ),
          ),
          GlassIconButton(
            icon: Icons.refresh_rounded,
            size: 36,
            onPressed: () {
              if (_scroll.hasClients) _scroll.jumpTo(0);
              _loadFirst();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(bool isDark) {
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    if (_moreError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载更多失败',
                style: TextStyle(fontSize: 12, color: textSub)),
            const SizedBox(height: 8),
            GlassButton(text: '重试', height: 34, onPressed: _retryMore),
          ],
        ),
      );
    }
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.only(top: 6, bottom: 26),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: JXColors.primary),
          ),
        ),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        child: Center(
          child: Text('没有更多了',
              style: TextStyle(fontSize: 12, color: textSub)),
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}

/// 空态 / 首屏失败态（居中图标 + 文案 + 重试按钮）
class _MessageView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String actionText;
  final VoidCallback onAction;

  const _MessageView({
    required this.icon,
    required this.title,
    required this.actionText,
    required this.onAction,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: textSub),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: textColor),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: textSub),
              ),
            ],
            const SizedBox(height: 16),
            GlassButton(text: actionText, onPressed: onAction),
          ],
        ),
      ),
    );
  }
}
