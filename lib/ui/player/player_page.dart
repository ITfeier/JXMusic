import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants.dart';
import '../../models/song.dart';
import '../../models/lyric.dart';
import '../../providers.dart';
import '../../services/download_service.dart';
import '../../services/library_store.dart';
import '../../services/playback.dart';
import '../../services/player_service.dart';
import '../dialogs.dart';
import '../glass.dart';
import '../layout.dart';
import 'vinyl_disc.dart';

/// 全屏播放页（液态玻璃 + 黑胶唱片 + 歌词三态）
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  bool _showLyrics = false;

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerServiceProvider);
    final song = player.currentSong;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    if (song == null) {
      return const Scaffold(body: SizedBox());
    }

    final progress = player.duration.inMilliseconds > 0
        ? player.position.inMilliseconds / player.duration.inMilliseconds
        : 0.0;

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
              // 顶部栏
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    GlassIconButton(
                      icon: Icons.keyboard_arrow_down_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Expanded(
                      child: Column(
                        children: [
                          Text(
                            '正在播放',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                          SizedBox(height: 2),
                          Text(
                            JXConstants.appName,
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                                fontWeight: FontWeight.w400),
                          ),
                        ],
                      ),
                    ),
                    GlassIconButton(
                      icon: Icons.more_horiz_rounded,
                      size: 36,
                      onPressed: _showMoreSheet,
                    ),
                  ],
                ),
              ),

              // 主体
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _showLyrics
                      ? _LyricsView(
                          key: const ValueKey('lyrics'),
                          lyrics: player.lyrics,
                          status: player.lyricsStatus,
                          currentIndex: player.lyricIndex,
                          onRetry: player.retryLyrics,
                          textColor: textColor,
                          textSub: textSub,
                        )
                      : _AlbumArtView(
                          key: const ValueKey('art'),
                          song: song,
                          spinning: player.playing,
                          textColor: textColor,
                          textSub: textSub,
                        ),
                ),
              ),

              // 控制区
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: Column(
                  children: [
                    // 音源切换二级按钮：仅同一首歌存在多个平台音源时显示，
                    // 点击弹出「选择音源」面板（替代原先标题下方的横向音源条）。
                    if (player.currentSources.length > 1)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: _SourceSwitchButton(
                            onTap: _showSourceSheet,
                          ),
                        ),
                      ),
                    // 进度条
                    Row(
                      children: [
                        Text(_fmt(player.position),
                            style: TextStyle(fontSize: 11, color: textSub)),
                        Expanded(
                          child: Slider(
                            value: (progress * 1000).clamp(0, 1000),
                            max: 1000,
                            activeColor: JXColors.primary,
                            inactiveColor: Colors.grey.withValues(alpha: 0.2),
                            onChanged: (v) async {
                              if (player.duration.inMilliseconds > 0) {
                                await player.seek(Duration(
                                    milliseconds:
                                        (v / 1000 * player.duration.inMilliseconds)
                                            .round()));
                              }
                            },
                          ),
                        ),
                        Text(_fmt(player.duration),
                            style: TextStyle(fontSize: 11, color: textSub)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 控制按钮：左右两侧等宽均分，保证主播放键始终水平居中、各按钮垂直居中对齐
                    Row(
                      children: [
                        Expanded(
                          child: Center(
                            child: GlassIconButton(
                              icon: player.loopMode == 3
                                  ? Icons.shuffle_rounded
                                  : player.loopMode == 1
                                      ? Icons.repeat_one_rounded
                                      : Icons.repeat_rounded,
                              size: 40,
                              color: player.loopMode != 2
                                  ? JXColors.primary
                                  : null,
                              onPressed: () => _cycleLoop(player),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: GlassIconButton(
                              icon: Icons.skip_previous_rounded,
                              size: 46,
                              onPressed: () => player.previous(),
                            ),
                          ),
                        ),
                        // 主播放键（固定宽度，居中）
                        SizedBox(
                          width: 84,
                          child: Center(
                            child: GestureDetector(
                              onTap: () => player.toggle(),
                              child: Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      JXColors.primary,
                                      JXColors.accent
                                    ],
                                  ),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: JXColors.primary
                                          .withValues(alpha: 0.45),
                                      blurRadius: 24,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  player.playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 42,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: GlassIconButton(
                              icon: Icons.skip_next_rounded,
                              size: 46,
                              onPressed: () => player.next(),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: GlassIconButton(
                              icon: _showLyrics
                                  ? Icons.album_rounded
                                  : Icons.lyrics_rounded,
                              size: 40,
                              color: _showLyrics ? JXColors.primary : null,
                              onPressed: () {
                                setState(() => _showLyrics = !_showLyrics);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // 音量 + 倍速（图标定宽居中，滑块与倍速按钮垂直对齐）
                    SizedBox(
                      height: 32,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 24,
                            child: GestureDetector(
                              onTap: player.toggleMute,
                              behavior: HitTestBehavior.opaque,
                              child: Icon(
                                player.muted
                                    ? Icons.volume_off_rounded
                                    : Icons.volume_down_rounded,
                                size: 18,
                                color: player.muted
                                    ? JXColors.accentPink
                                    : textSub,
                              ),
                            ),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6),
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 13),
                              ),
                              child: Slider(
                                value: player.muted ? 0 : player.volume,
                                max: 100,
                                activeColor: JXColors.primary,
                                inactiveColor:
                                    Colors.grey.withValues(alpha: 0.2),
                                onChanged: (v) => player.setVolume(v),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 24,
                            child: GestureDetector(
                              onTap: player.toggleMute,
                              behavior: HitTestBehavior.opaque,
                              child: Icon(
                                player.muted
                                    ? Icons.volume_off_rounded
                                    : Icons.volume_up_rounded,
                                size: 18,
                                color: player.muted
                                    ? JXColors.accentPink
                                    : textSub,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _SpeedButton(
                            speed: player.speed,
                            onChanged: player.setSpeed,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 更多菜单：播放队列 / 下载 / 收藏 / 添加到歌单
  Future<void> _showMoreSheet() async {
    final song = ref.read(playerServiceProvider).currentSong;
    if (song == null) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _MoreSheet(song: song),
    );
    if (!mounted) return;
    switch (picked) {
      case 'queue':
        await showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (_) => const _QueueSheet(),
        );
      case 'download':
        await _downloadCurrent();
      case 'favorite':
        _toggleFavorite(song);
      case 'add_to_playlist':
        await _addToPlaylist(song);
    }
  }

  /// 音源切换二级按钮：弹出「选择音源」面板；切换成功关闭面板并提示。
  Future<void> _showSourceSheet() async {
    final player = ref.read(playerServiceProvider);
    if (player.currentSong == null) return;
    final switched = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SourceSheet(),
    );
    if (switched != true || !mounted) return;
    final actual = ref.read(playerServiceProvider).currentSong;
    if (actual == null) return;
    _toast('已切换到 ${JXPlatform.name(actual.platform)} 音源');
  }

  void _toggleFavorite(Song song) {
    final added = ref.read(libraryProvider).toggleFavorite(song);
    _toast(added ? '已收藏「${song.title}」' : '已取消收藏');
  }

  /// 添加到自建歌单：选择已有歌单或新建
  Future<void> _addToPlaylist(Song song) async {
    final store = ref.read(libraryProvider);
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _PlaylistPickerSheet(playlists: store.playlists),
    );
    if (!mounted || picked == null) return;
    if (picked == _PlaylistPickerSheet.createNew) {
      final name = await promptText(context, title: '新建歌单', hint: '歌单名称');
      if (name == null || !mounted) return;
      final id = ref.read(libraryProvider).createPlaylist(name);
      ref.read(libraryProvider).addSongToPlaylist(id, song);
      _toast('已添加到「$name」');
      return;
    }
    final playlist = ref.read(libraryProvider).playlistById(picked);
    final added = ref.read(libraryProvider).addSongToPlaylist(picked, song);
    final name = playlist?.name ?? '';
    _toast(added ? '已添加到「$name」' : '「$name」里已有这首歌');
  }

  /// 下载当前歌曲：先解析播放直链（未解析过时），带进度弹窗写入本地
  Future<void> _downloadCurrent() async {
    final song = ref.read(playerServiceProvider).currentSong;
    if (song == null) return;
    if (song.platform == JXPlatform.local) {
      _toast('本地文件已在磁盘上，无需下载');
      return;
    }
    final api = ref.read(musicHubProvider).api(song.platform);
    if (api == null) {
      _toast('该平台暂不支持下载');
      return;
    }
    final progress = ValueNotifier<double>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _DownloadProgressDialog(progress: progress, title: song.title),
    );
    try {
      final url = song.audioUrl ?? await api.getPlayUrl(song);
      if (url == null || url.isEmpty) {
        if (dialogOpen) navigator.pop();
        dialogOpen = false;
        _toast('无法获取下载链接：该歌曲可能需要登录对应平台或为 VIP 专享');
        return;
      }
      final saved = await DownloadService.instance.download(
        song.copyWith(audioUrl: url),
        onProgress: (v) => progress.value = v,
      );
      if (dialogOpen) navigator.pop();
      dialogOpen = false;
      _toast('已保存到：$saved');
    } catch (e) {
      if (dialogOpen) navigator.pop();
      dialogOpen = false;
      _toast('下载失败：$e');
    } finally {
      progress.dispose();
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _cycleLoop(PlayerService player) {
    final next = (player.loopMode + 1) % 4;
    player.setLoopMode(next);
  }
}

/// 播放页封面边长（纯函数，便于单测）：
/// 取「宽度 * 0.62」与「可用高度 - 文案块预算」的较小值，常态限制在
/// [140, 300]；高度极端不足（如系统超大字体）时允许继续缩小，优先保证不溢出。
///
/// 背景（用户真机反馈）：360x640dp 下播放页 Expanded 扣掉安全区后高度不足，
/// 固定 200~300 的大封面 + 标题/歌手/平台 Chip 会让 Column 溢出，Chip 被控制区
/// 右上角的「音源」按钮盖住。这里改为按实际可用高度收缩封面。
double jxPlayerCoverSize({
  required double maxWidth,
  required double maxHeight,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final byWidth = (maxWidth * 0.62).clamp(140.0, 300.0).toDouble();
  if (!maxHeight.isFinite) return byWidth;
  final textBlock = _jxPlayerTextBlockHeight(textScaler, maxHeight);
  // 预留 1dp 余量：文本行高存在浮点/字体度量的亚像素误差，避免刚好贴边被判溢出。
  final byHeight = maxHeight - textBlock - 1;
  if (byHeight < 140) return byHeight.clamp(0.0, 140.0).toDouble();
  return math.min(byWidth, byHeight);
}

/// 矮屏（可用高度 <420dp，如 360x640 手机）收紧布局：封面与文案间距 12、
/// 副标题与平台 Chip 间距 8；常规屏保持 40 / 12 的原观感。
bool jxPlayerCompact(double maxHeight) =>
    maxHeight.isFinite && maxHeight < 420;

/// 封面与文案之间的间距：矮屏 12，常规 40。
double jxPlayerCoverGap(double maxHeight) => jxPlayerCompact(maxHeight) ? 12 : 40;

// 显式行高，保证不同字体/设备上行高可预测（M3 bodyMedium 默认 1.43 会偏高）。
const double _jxTitleLineHeight = 1.3;
const double _jxSubtitleLineHeight = 1.3;
const double _jxChipLabelLineHeight = 1.2;

/// 封面下方文案块的保守高度预算（与实际渲染用同一组行高，避免估小导致溢出）：
/// 标题最多两行 + 歌手·专辑一行 + 平台 Chip（Chip 已设 shrinkWrap，最小高 32）。
double _jxPlayerTextBlockHeight(TextScaler textScaler, double maxHeight) {
  final compact = jxPlayerCompact(maxHeight);
  final title = textScaler.scale(22) * _jxTitleLineHeight * 2;
  final subtitle = textScaler.scale(14) * _jxSubtitleLineHeight;
  final chip = math.max(
    32.0,
    textScaler.scale(11) * _jxChipLabelLineHeight + 16, // Chip 上下 padding 各 8
  );
  return jxPlayerCoverGap(maxHeight) +
      title +
      8 +
      subtitle +
      (compact ? 8 : 12) +
      chip;
}

/// 专辑封面视图（圆形黑胶唱片：播放中旋转、暂停停住 + 文案）
class _AlbumArtView extends StatelessWidget {
  final Song song;

  /// 是否播放中：交给 [JXVinylDisc] 控制 30s/圈旋转，暂停时停在当前角度。
  final bool spinning;
  final Color textColor;
  final Color textSub;

  const _AlbumArtView({
    super.key,
    required this.song,
    required this.spinning,
    required this.textColor,
    required this.textSub,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final size = jxPlayerCoverSize(
          maxWidth: width,
          maxHeight: constraints.maxHeight,
          textScaler: MediaQuery.textScalerOf(context),
        );
        final gap = jxPlayerCoverGap(constraints.maxHeight);
        final compact = jxPlayerCompact(constraints.maxHeight);
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (size > 0) ...[
                JXVinylDisc(
                  coverUrl: song.coverUrl,
                  size: size,
                  spinning: spinning,
                ),
                SizedBox(height: gap),
              ],
              Text(
                song.title,
                style: TextStyle(
                  fontSize: 22,
                  height: _jxTitleLineHeight,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                '${song.artist} · ${song.album}',
                style: TextStyle(
                  fontSize: 14,
                  height: _jxSubtitleLineHeight,
                  color: textSub,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: compact ? 8 : 12),
              Chip(
                label: Text(
                  song.displayPlatform,
                  style: const TextStyle(
                    fontSize: 11,
                    height: _jxChipLabelLineHeight,
                  ),
                ),
                backgroundColor: Colors.transparent,
                side: BorderSide(color: textSub.withValues(alpha: 0.4)),
                visualDensity: VisualDensity.compact,
                // 平台 Chip 不可点击：不占 48dp 的最小点按高度，矮屏也能塞下
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 歌词滚动视图：按 [LyricsStatus] 渲染加载中 / 暂无歌词 / 加载失败可重试 /
/// 正常滚动高亮列表（当前行自动滚动到视口中央）。
class _LyricsView extends StatefulWidget {
  final List<LyricLine> lyrics;
  final LyricsStatus status;
  final int currentIndex;
  final VoidCallback onRetry;
  final Color textColor;
  final Color textSub;

  const _LyricsView({
    super.key,
    required this.lyrics,
    required this.status,
    required this.currentIndex,
    required this.onRetry,
    required this.textColor,
    required this.textSub,
  });

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  static const double _lineHeight = 44;
  static const double _verticalPadding = 140;

  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _scheduleScroll(jump: true);
  }

  @override
  void didUpdateWidget(covariant _LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics) {
      // 换歌：直接跳到第一行，避免沿用上一首的滚动位置
      _scheduleScroll(jump: true);
      return;
    }
    if (oldWidget.currentIndex != widget.currentIndex) {
      _scheduleScroll();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 把当前歌词行滚动到视口中央（首尾行会被 scroll extent 自然夹住）
  void _scheduleScroll({bool jump = false}) {
    final index = widget.currentIndex;
    if (index < 0 || index >= widget.lyrics.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      final target = _verticalPadding +
          index * _lineHeight +
          _lineHeight / 2 -
          position.viewportDimension / 2;
      final clamped = target.clamp(
          position.minScrollExtent, position.maxScrollExtent);
      if (jump) {
        _controller.jumpTo(clamped);
      } else {
        _controller.animateTo(
          clamped,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 歌词三态（PRD R2）：加载中不得显示「暂无歌词」；失败可重试。
    if (widget.status == LyricsStatus.loading) return _loadingView();
    if (widget.status == LyricsStatus.error) return _errorView();
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) return _emptyView();
    return ListView.builder(
      controller: _controller,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
      itemCount: lyrics.length,
      itemBuilder: (context, i) {
        final active = i == widget.currentIndex;
        return AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 250),
          style: TextStyle(
            fontSize: active ? 17 : 13.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            color: active ? widget.textColor : widget.textSub,
          ),
          child: SizedBox(
            height: _lineHeight,
            child: Center(
              child: Text(
                lyrics[i].text,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 加载中：居中转圈 + 「歌词加载中…」
  Widget _loadingView() {
    return Center(
      child: Column(
        key: const Key('lyricsLoading'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: JXColors.primary,
            ),
          ),
          const SizedBox(height: 14),
          Text('歌词加载中…',
              style: TextStyle(color: widget.textSub, fontSize: 14)),
        ],
      ),
    );
  }

  /// 无歌词：图标 + 「暂无歌词」
  Widget _emptyView() {
    return Center(
      child: Column(
        key: const Key('lyricsEmpty'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lyrics_rounded, size: 48, color: widget.textSub),
          const SizedBox(height: 12),
          Text('暂无歌词',
              style: TextStyle(color: widget.textSub, fontSize: 14)),
        ],
      ),
    );
  }

  /// 加载失败：图标 + 「歌词加载失败」+ 重试按钮（调 player.retryLyrics()）
  Widget _errorView() {
    return Center(
      child: Column(
        key: const Key('lyricsError'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 44, color: widget.textSub),
          const SizedBox(height: 12),
          Text('歌词加载失败',
              style: TextStyle(color: widget.textSub, fontSize: 14)),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('lyricsRetryButton'),
            onPressed: widget.onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
            style: TextButton.styleFrom(foregroundColor: JXColors.primary),
          ),
        ],
      ),
    );
  }
}

/// 更多菜单弹层（播放队列 / 下载 / 收藏 / 添加到歌单）
class _MoreSheet extends ConsumerWidget {
  final Song song;

  const _MoreSheet({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    final favorite = ref.watch(libraryProvider).isFavorite(song);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: GlassCard(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.queue_music_rounded,
                    color: JXColors.primary),
                title: const Text('播放队列', style: TextStyle(fontSize: 14)),
                onTap: () => Navigator.of(context).pop('queue'),
              ),
              ListTile(
                leading: const Icon(Icons.download_rounded,
                    color: JXColors.primary),
                title: const Text('下载当前歌曲', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  '保存到下载目录下的 JXMusic 文件夹',
                  style: TextStyle(fontSize: 11, color: sub),
                ),
                onTap: () => Navigator.of(context).pop('download'),
              ),
              ListTile(
                leading: Icon(
                  favorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: JXColors.accentPink,
                ),
                title: Text(
                  favorite ? '取消收藏' : '收藏歌曲',
                  style: const TextStyle(fontSize: 14),
                ),
                onTap: () => Navigator.of(context).pop('favorite'),
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded,
                    color: JXColors.primary),
                title: const Text('添加到歌单', style: TextStyle(fontSize: 14)),
                onTap: () => Navigator.of(context).pop('add_to_playlist'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选择目标歌单（底部弹层）
class _PlaylistPickerSheet extends StatelessWidget {
  static const String createNew = '__new__';

  final List<UserPlaylist> playlists;

  const _PlaylistPickerSheet({required this.playlists});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: GlassCard(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('添加到歌单',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              ListTile(
                leading: const Icon(Icons.add_rounded, color: JXColors.primary),
                title: const Text('新建歌单', style: TextStyle(fontSize: 14)),
                onTap: () => Navigator.of(context).pop(createNew),
              ),
              if (playlists.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: Text(
                    '还没有自建歌单，先新建一个吧',
                    style: TextStyle(fontSize: 12, color: sub),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in playlists)
                        ListTile(
                          leading: const Icon(Icons.queue_music_rounded,
                              color: JXColors.primary),
                          title: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14),
                          ),
                          subtitle: Text(
                            '${p.songCount} 首',
                            style: TextStyle(fontSize: 11, color: sub),
                          ),
                          onTap: () => Navigator.of(context).pop(p.id),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 下载进度弹窗
class _DownloadProgressDialog extends StatelessWidget {
  final ValueNotifier<double> progress;
  final String title;

  const _DownloadProgressDialog({
    required this.progress,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('正在下载', style: TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, value, _) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: value > 0 ? value : null,
                    color: JXColors.primary,
                    backgroundColor: Colors.grey.withValues(alpha: 0.2),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    value > 0
                        ? '${(value * 100).toStringAsFixed(0)}%'
                        : '连接中…',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 倍速选择按钮
class _SpeedButton extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onChanged;

  const _SpeedButton({required this.speed, required this.onChanged});

  static const List<double> _options = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<double>(
      tooltip: '播放速度',
      initialValue: speed,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final v in _options)
          PopupMenuItem(value: v, child: Text(jxFormatSpeed(v))),
      ],
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: (isDark ? JXColors.glassDark : JXColors.glassLight)
              .withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark
                ? JXColors.glassStrokeDark
                : JXColors.glassStrokeLight,
          ),
        ),
        child: Text(
          jxFormatSpeed(speed),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            height: 1.1,
            color: speed == 1.0 ? null : JXColors.primary,
          ),
        ),
      ),
    );
  }
}

/// 播放队列底部弹层
class _QueueSheet extends ConsumerWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);
    final queue = player.queue;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: GlassCard(
          borderRadius: BorderRadius.circular(28),
          padding: const EdgeInsets.all(0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Text(
                '播放队列 (${queue.length})',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: queue.length,
                  separatorBuilder: (_, _) => const Divider(indent: 60),
                  itemBuilder: (context, i) {
                    final s = queue[i];
                    final active = i == player.currentIndex;
                    return ListTile(
                      leading: GlassCover(url: s.coverUrl, size: 40,
                          borderRadius: BorderRadius.circular(8)),
                      title: Text(s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: active
                                ? JXColors.primary
                                : (isDark
                                    ? JXColors.textOnDark
                                    : JXColors.textPrimary),
                          )),
                      subtitle: Text('${s.artist} · ${s.displayPlatform}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: textSub)),
                      trailing: IconButton(
                        icon: Icon(Icons.close_rounded,
                            size: 18, color: textSub),
                        onPressed: () => player.removeFromQueue(i),
                      ),
                      onTap: () => player.playSong(s),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => player.clearQueue(),
                child: const Text('清空队列'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 音源切换二级按钮（控制区、进度条上方右侧）：
/// 按用户要求只显示「音源」二字，不再显示 swap 图标 / 平台名 / 展开箭头；
/// 保留玻璃胶囊视觉，点击弹出「选择音源」面板，Semantics/Tooltip 供读屏与长按提示。
class _SourceSwitchButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SourceSwitchButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return Semantics(
      button: true,
      label: '切换音源',
      child: Tooltip(
        message: '切换音源',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            // 注意：不要给这个 Container 设置 alignment！
            // Container 带 alignment 时会在 bounded 约束下撑满可用宽度，
            // 曾导致「音源」胶囊变成整行通栏（真机/截图回归）。
            // 这里用 Row(mainAxisSize.min) 决定内容宽度，minWidth 64 只保证点按尺寸。
            key: const Key('sourceSwitchButton'),
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            constraints: const BoxConstraints(minWidth: 64),
            decoration: BoxDecoration(
              color: (isDark ? JXColors.glassDark : JXColors.glassLight)
                  .withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: isDark
                    ? JXColors.glassStrokeDark
                    : JXColors.glassStrokeLight,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '音源',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: textSub,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「选择音源」底部面板：
/// - 当前音源行不可点；VIP 音源标 `VIP`，未登录且为 VIP 时额外标「需登录」；
/// - 切换中禁用整表并显示 loading；
/// - 切换成功关闭面板（返回 true），失败留在面板内并在对应行展示原因。
class _SourceSheet extends ConsumerStatefulWidget {
  const _SourceSheet();

  @override
  ConsumerState<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends ConsumerState<_SourceSheet> {
  bool _switching = false;
  String? _error;
  String? _errorFor;

  Future<void> _switch(Song source) async {
    if (_switching) return;
    final player = ref.read(playerServiceProvider);
    if (!canSwitchToSource(source, player.currentSong)) return;
    setState(() {
      _switching = true;
      _error = null;
      _errorFor = null;
    });
    var succeeded = false;
    String? message;
    try {
      final result = await switchSource(ref, source);
      if (!mounted) return; // 面板已被用户关闭：不再更新 UI
      if (result.ok) {
        succeeded = true;
        Navigator.of(context).pop(true);
        return;
      }
      message = result.error ?? '切换音源失败';
    } catch (e) {
      // 任意异常都要复位“切换中”，否则面板会一直卡 loading。
      message = '切换音源失败：$e';
    } finally {
      if (mounted && !succeeded) {
        final text = message ?? '切换音源失败';
        setState(() {
          _switching = false;
          _error = text;
          _errorFor = source.globalId;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(text)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerServiceProvider);
    final current = player.currentSong;
    final sources = player.orderedSources;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: GlassCard(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 6, bottom: 2),
                child: Text('选择音源',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              if (current != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '当前：${current.displayPlatform} · 切换后保留播放进度',
                    style: TextStyle(fontSize: 11, color: textSub),
                  ),
                ),
              if (_switching)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: JXColors.primary,
                    backgroundColor: Colors.transparent,
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in sources)
                      _SourceTile(
                        source: s,
                        current:
                            current != null && s.globalId == current.globalId,
                        loggedIn:
                            ref.watch(accountProvider(s.platform)) != null,
                        switching: _switching,
                        error: _errorFor == s.globalId ? _error : null,
                        onTap: () => _switch(s),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 音源面板中的一行：平台色点 + 平台名 + 当前/VIP/（VIP 且未登录）需登录标记 + 失败原因
class _SourceTile extends StatelessWidget {
  final Song source;
  final bool current;
  final bool loggedIn;
  final bool switching;
  final String? error;
  final VoidCallback onTap;

  const _SourceTile({
    required this.source,
    required this.current,
    required this.loggedIn,
    required this.switching,
    required this.error,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    final color = JXPlatform.color(source.platform);
    final enabled = !current && !switching;
    return ListTile(
      enabled: enabled,
      onTap: enabled ? onTap : null,
      dense: true,
      leading: SizedBox(
        width: 18,
        child: Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
      title: Wrap(
        spacing: 6,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            JXPlatform.name(source.platform),
            style: TextStyle(
              fontSize: 14,
              fontWeight: current ? FontWeight.w700 : FontWeight.w400,
              color: current ? color : null,
            ),
          ),
          if (current) _sourceBadge('当前 · 播放中', JXColors.primary),
          if (source.vip) _sourceBadge('VIP', JXColors.accentPink),
          // 「需登录」只标在 VIP 音源上：免费音源未登录也能播，避免误导。
          if (!loggedIn && source.vip) _sourceBadge('需登录', textSub),
        ],
      ),
      subtitle: error == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                error!,
                style: const TextStyle(
                    fontSize: 11.5, color: JXColors.accentPink),
              ),
            ),
      trailing: current
          ? const Icon(Icons.graphic_eq_rounded,
              size: 16, color: JXColors.primary)
          : null,
    );
  }
}

Widget _sourceBadge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 9.5, color: color, fontWeight: FontWeight.w700),
      ),
    );