import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants.dart';
import '../../models/song.dart';
import '../../models/lyric.dart';
import '../../providers.dart';
import '../../services/player_service.dart';
import '../glass.dart';

/// 全屏播放页（液态玻璃 + 旋转封面 + 歌词）
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;
  bool _showLyrics = false;
  Timer? _lyricLoadTimer;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
    _loadLyricsIfNeeded();
  }

  @override
  void dispose() {
    _spin.dispose();
    _lyricLoadTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadLyricsIfNeeded() async {
    _lyricLoadTimer?.cancel();
    _lyricLoadTimer = Timer(const Duration(milliseconds: 1200), () async {
      if (!mounted) return;
      // 首页/搜索页播放时通常已经加载过歌词，避免重复请求
      final current = ref.read(playerServiceProvider);
      if (current.lyrics.isNotEmpty) return;
      final song = current.currentSong;
      if (song == null) return;
      final hub = ref.read(musicHubProvider);
      final api = hub.api(song.platform);
      if (api == null) return;
      final lrc = await api.getLyrics(song);
      if (!mounted) return;
      ref
          .read(playerServiceProvider)
          .setLyrics(LyricParser.parseLrc(lrc));
    });
  }

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
                      onPressed: () {
                        showModalBottomSheet(
                          context: context,
                          backgroundColor: Colors.transparent,
                          builder: (_) => const _QueueSheet(),
                        );
                      },
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
                          currentIndex: player.lyricIndex,
                          textColor: textColor,
                          textSub: textSub,
                        )
                      : _AlbumArtView(
                          key: const ValueKey('art'),
                          song: song,
                          spin: _spin,
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
                    // 控制按钮
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GlassIconButton(
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
                        const SizedBox(width: 24),
                        GlassIconButton(
                          icon: Icons.skip_previous_rounded,
                          size: 48,
                          onPressed: () => player.previous(),
                        ),
                        const SizedBox(width: 24),
                        // 主播放键
                        GestureDetector(
                          onTap: () => player.toggle(),
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [JXColors.primary, JXColors.accent],
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
                        const SizedBox(width: 24),
                        GlassIconButton(
                          icon: Icons.skip_next_rounded,
                          size: 48,
                          onPressed: () => player.next(),
                        ),
                        const SizedBox(width: 24),
                        GlassIconButton(
                          icon: _showLyrics
                              ? Icons.album_rounded
                              : Icons.lyrics_rounded,
                          size: 40,
                          color: _showLyrics ? JXColors.primary : null,
                          onPressed: () {
                            setState(() => _showLyrics = !_showLyrics);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // 音量
                    Row(
                      children: [
                        Icon(Icons.volume_down_rounded,
                            size: 18,
                            color: textSub),
                        Expanded(
                          child: Slider(
                            value: player.volume,
                            max: 100,
                            activeColor: JXColors.primary,
                            inactiveColor: Colors.grey.withValues(alpha: 0.2),
                            onChanged: (v) => player.setVolume(v),
                          ),
                        ),
                        Icon(Icons.volume_up_rounded,
                            size: 18,
                            color: textSub),
                      ],
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

  void _cycleLoop(PlayerService player) {
    final next = (player.loopMode + 1) % 4;
    player.setLoopMode(next);
  }
}

/// 专辑封面视图（旋转 + 液态玻璃氛围）
class _AlbumArtView extends StatelessWidget {
  final Song song;
  final Animation<double> spin;
  final Color textColor;
  final Color textSub;

  const _AlbumArtView({
    super.key,
    required this.song,
    required this.spin,
    required this.textColor,
    required this.textSub,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final size = (w * 0.62).clamp(200.0, 300.0); // 手机 360~430dp 自适应大封面
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          RotationTransition(
            turns: spin,
            child: _GlowCover(url: song.coverUrl, size: size),
          ),
          const SizedBox(height: 40),
          Text(
            song.title,
            style: TextStyle(
              fontSize: 22,
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
            style: TextStyle(fontSize: 14, color: textSub),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          Chip(
            label: Text(song.displayPlatform,
                style: const TextStyle(fontSize: 11)),
            backgroundColor: Colors.transparent,
            side: BorderSide(color: textSub.withValues(alpha: 0.4)),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// 液态玻璃大封面（外圈光环 + 深投影）
class _GlowCover extends StatelessWidget {
  final String url;
  final double size;

  const _GlowCover({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final r = size * 0.14;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.05),
            blurRadius: 0,
            spreadRadius: 14,
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.035),
            blurRadius: 0,
            spreadRadius: 30,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 40,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      child: GlassCover(
          url: url,
          size: size,
          borderRadius: BorderRadius.circular(r)),
    );
  }
}

/// 歌词滚动视图（当前行自动滚动到视口中央）
class _LyricsView extends StatefulWidget {
  final List<LyricLine> lyrics;
  final int currentIndex;
  final Color textColor;
  final Color textSub;

  const _LyricsView({
    super.key,
    required this.lyrics,
    required this.currentIndex,
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
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) {
      return Center(
        child: Column(
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
