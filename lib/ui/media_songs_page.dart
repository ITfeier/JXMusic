import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../services/playback.dart';
import 'glass.dart';
import 'player/player_bar.dart';

/// 歌手页 / 专辑页共用的「歌曲集合页」：
/// 头部（封面 + 标题 + 副标题 · 实际加载首数 + 播放全部）+ 分页歌曲列表
/// （列表尾部「加载更多」）+ 底部常驻迷你播放条。
///
/// 与 [PlaylistDetailPage] 同为整页路由，会盖住壳层 PlayerBar，故自带一份。
class MediaSongsPage extends ConsumerStatefulWidget {
  final String headerLabel; // 顶栏标题（如「歌手」「专辑」）
  final String title; // 大标题（歌手名 / 专辑名）
  final String subtitle; // 静态副标题（平台 · 元信息）
  final String coverUrl;
  final int gradientIndex;
  final bool roundCover; // 歌手用圆形头像
  final String emptyText;
  final Future<List<Song>> Function(int page, int size) loader;

  const MediaSongsPage({
    super.key,
    required this.headerLabel,
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.loader,
    this.gradientIndex = 0,
    this.roundCover = false,
    this.emptyText = '暂无歌曲',
  });

  @override
  ConsumerState<MediaSongsPage> createState() => _MediaSongsPageState();
}

class _MediaSongsPageState extends ConsumerState<MediaSongsPage> {
  static const int _pageSize = 50;

  bool _loading = true;
  bool _loadingMore = false;
  List<Song> _songs = const [];
  String? _error;
  int _page = 1;
  bool _hasMore = false;

  /// 请求序号：重试 / 加载更多交叉时，慢的旧请求回来不允许覆盖新状态。
  int _requestSeq = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    final seq = ++_requestSeq;
    final page = reset ? 1 : _page + 1;
    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final songs = await widget.loader(page, _pageSize);
      if (seq != _requestSeq || !mounted) return;
      setState(() {
        if (reset) {
          _songs = songs;
          _page = 1;
        } else {
          _songs = [..._songs, ...songs];
          _page = page;
        }
        // 不足一页说明到底了，不再展示「加载更多」
        _hasMore = songs.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (seq != _requestSeq || !mounted) return;
      setState(() {
        if (reset) _songs = const [];
        _loading = false;
        _loadingMore = false;
        _error = '加载失败：$e';
      });
    }
  }

  /// 头部副标题：静态元信息 + 按实际加载状态显示首数（不展示误导性的「0 首」）
  String get _meta {
    final String countText;
    if (_loading) {
      countText = '加载中…';
    } else if (_error != null) {
      countText = '加载失败';
    } else if (_songs.isEmpty) {
      countText = '暂无歌曲';
    } else {
      countText = '${_songs.length} 首';
    }
    final sub = widget.subtitle.trim();
    return sub.isEmpty ? countText : '$sub · $countText';
  }

  Future<void> _playAll() async {
    if (_songs.isEmpty) return;
    final ok = await resolveAndPlay(ref, _songs.first, queue: _songs);
    if (!ok && mounted) _toastPlayFailed();
  }

  Future<void> _play(Song song) async {
    final ok = await resolveAndPlay(ref, song, queue: _songs);
    if (!ok && mounted) _toastPlayFailed();
  }

  void _toastPlayFailed() {
    jxShowNotice(context, '无法播放：该歌曲可能需要先在设置里登录对应平台');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

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
              // 顶栏
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                child: Row(
                  children: [
                    GlassIconButton(
                      icon: Icons.arrow_back_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.headerLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: textColor),
                      ),
                    ),
                  ],
                ),
              ),
              // 头部信息
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    GlassCover(
                      url: widget.coverUrl,
                      size: 96,
                      borderRadius: widget.roundCover
                          ? BorderRadius.circular(48)
                          : BorderRadius.circular(22),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: textColor),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _meta,
                            style: TextStyle(fontSize: 12, color: textSub),
                          ),
                          const SizedBox(height: 12),
                          GlassButton(
                            text: '播放全部',
                            icon: Icons.play_arrow_rounded,
                            primary: true,
                            onPressed: _songs.isEmpty ? null : _playAll,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // 歌曲列表
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: JXColors.primary))
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_error!,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Colors.redAccent)),
                                  const SizedBox(height: 12),
                                  GlassButton(
                                    text: '重试',
                                    icon: Icons.refresh_rounded,
                                    onPressed: () => _load(reset: true),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : _songs.isEmpty
                            ? _buildEmptyState(textSub)
                            : _buildSongList(textColor, textSub),
              ),
              // 底部常驻迷你播放条：整页路由会盖住壳层 PlayerBar，本页自带一份
              const PlayerBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSongList(Color textColor, Color textSub) {
    final showMore = _hasMore && _error == null;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      itemCount: _songs.length + (showMore ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 60),
      itemBuilder: (context, i) {
        if (i >= _songs.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Center(
              child: GlassButton(
                text: _loadingMore ? '加载中…' : '加载更多',
                icon: Icons.expand_more_rounded,
                height: 38,
                onPressed: _loadingMore ? null : () => _load(reset: false),
              ),
            ),
          );
        }
        final s = _songs[i];
        return ListTile(
          leading: SizedBox(
            width: 32,
            child: Text(
              '${i + 1}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: i < 3 ? JXColors.accentPink : textSub,
              ),
            ),
          ),
          title: Text(
            s.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 14, color: textColor, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            s.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: textSub),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.vip)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: JXColors.accentPink.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('VIP',
                        style: TextStyle(
                            fontSize: 10,
                            color: JXColors.accentPink,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              GlassIconButton(
                icon: Icons.play_arrow_rounded,
                size: 36,
                color: JXColors.primary,
                onPressed: () => _play(s),
              ),
            ],
          ),
          onTap: () => _play(s),
        );
      },
    );
  }

  /// 空态：明确提示 + 重试
  Widget _buildEmptyState(Color textSub) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.queue_music_rounded, size: 44, color: textSub),
            const SizedBox(height: 12),
            Text(
              widget.emptyText,
              style: TextStyle(fontSize: 14, color: textSub),
            ),
            const SizedBox(height: 4),
            Text(
              '平台接口可能调整，或内容未公开',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: textSub),
            ),
            const SizedBox(height: 12),
            GlassButton(
              text: '重试',
              icon: Icons.refresh_rounded,
              onPressed: () => _load(reset: true),
            ),
          ],
        ),
      ),
    );
  }
}
