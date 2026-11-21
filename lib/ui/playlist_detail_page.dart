import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/playback.dart';
import 'glass.dart';
import 'player/player_bar.dart';

/// 歌单详情页
class PlaylistDetailPage extends ConsumerStatefulWidget {
  final Playlist playlist;
  const PlaylistDetailPage({super.key, required this.playlist});

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  bool _loading = true;
  List<Song> _songs = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hub = ref.read(musicHubProvider);
      final api = hub.api(widget.playlist.platform);
      if (api == null) {
        setState(() => _error = '该平台暂不支持歌单');
      } else {
        final songs = await api.playlistSongs(widget.playlist);
        if (mounted) setState(() => _songs = songs);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '加载失败：$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  /// 头部副标题：QQ 等平台的歌单广场接口不返回歌曲数（songCount 恒 0），
  /// 不能直接展示 playlist.songCount；加载完成后按实际已加载首数显示，
  /// 未加载/失败时显示状态文案，不展示「0 首」这种误导性数字。
  String get _playlistMeta {
    final creator = widget.playlist.creator.trim();
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
    return creator.isEmpty ? countText : '$creator · $countText';
  }

  Future<void> _playAll() async {
    if (_songs.isEmpty) return;
    await _play(_songs.first);
  }

  Future<void> _play(Song song) async {
    // 快照法（freshApiError）：resolveAndPlay 内部跨平台兜底会触发多个平台
    // getPlayUrl，这里只取本平台「本次新增」的失败原因，不读陈旧 lastError。
    final api = ref.read(musicHubProvider).api(song.platform);
    final before = api?.lastError;
    final ok = await resolveAndPlay(ref, song, queue: _songs);
    if (ok || !mounted) return;
    final fresh =
        api == null ? null : freshApiError(before, api.lastError);
    _toastPlayFailed(song, fresh);
  }

  /// 收藏 / 取消收藏歌单（本机），音乐库「收藏歌单」tab 顶部展示
  void _toggleCollect() {
    final store = ref.read(libraryProvider);
    final added = store.toggleCollectedPlaylist(widget.playlist);
    if (!mounted) return;
    jxShowNotice(
        context, added ? '已收藏「${widget.playlist.title}」' : '已取消收藏');
  }

  /// 播放失败提示：优先展示平台 API 本次给出的具体原因（VIP/付费/版权/登录态
  /// 过期），只有「未登录且是 VIP 歌」才提示先登录——已登录用户不再被误导
  /// 「需要先在设置里登录」（真机反馈：绿钻账号老被提示需要登录）。
  void _toastPlayFailed(Song song, String? freshReason) {
    final name = JXPlatform.name(song.platform);
    final loggedIn = ref.read(accountProvider(song.platform)) != null;
    if (song.vip && !loggedIn) {
      jxShowNotice(context, '需要先登录$name才能播放 VIP 音源');
      return;
    }
    final detail = (freshReason == null || freshReason.trim().isEmpty)
        ? (loggedIn ? '该歌曲在$name及跨平台均无可用音源' : '可能需要登录$name或受版权限制')
        : freshReason;
    jxShowNotice(context, '「${song.title}」无法播放：$detail');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    final p = widget.playlist;
    final collected =
        ref.watch(libraryProvider).isCollected(widget.playlist);

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
              // 头部
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
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
                    IconButton(
                      icon: Icon(
                        collected
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        size: 24,
                        color: collected
                            ? JXColors.primary
                            : textColor.withValues(alpha: 0.7),
                      ),
                      tooltip: collected ? '取消收藏' : '收藏歌单',
                      onPressed: _toggleCollect,
                    ),
                  ],
                ),
              ),
              // 歌单信息
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    GlassCover(url: p.coverUrl, size: 96,
                        borderRadius: BorderRadius.circular(22)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: textColor),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _playlistMeta,
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
                                    onPressed: _load,
                                  ),
                                ],
                              ),
                            ),
                          )
                        : _songs.isEmpty
                            ? _buildEmptyState(textSub)
                            : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                            itemCount: _songs.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1, indent: 60),
                            itemBuilder: (context, i) {
                              final s = _songs[i];
                              return ListTile(
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
                                  s.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: textColor,
                                      fontWeight: FontWeight.w500),
                                ),
                                subtitle: Text(
                                  s.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11, color: textSub),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (s.vip)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: JXColors.accentPink
                                                .withValues(alpha: 0.15),
                                            borderRadius:
                                                BorderRadius.circular(6),
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
                          ),
              ),
              // 底部常驻迷你播放条：歌单详情是 Navigator.push 的整页路由，
              // 会盖住 ShellPage 上的 PlayerBar，所以本页要自带一份。
              const PlayerBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// 空歌单态：明确提示 + 重试（原实现 _songs 为空时正文全空白）
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
              '该歌单暂无歌曲',
              style: TextStyle(fontSize: 14, color: textSub),
            ),
            const SizedBox(height: 4),
            Text(
              '平台接口可能调整，或该歌单未公开歌曲',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: textSub),
            ),
            const SizedBox(height: 12),
            GlassButton(
              text: '重试',
              icon: Icons.refresh_rounded,
              onPressed: _load,
            ),
          ],
        ),
      ),
    );
  }
}
