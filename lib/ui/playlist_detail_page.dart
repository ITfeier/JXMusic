import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../models/lyric.dart';
import '../providers.dart';
import 'glass.dart';

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

  Future<void> _playAll() async {
    if (_songs.isEmpty) return;
    final first = _songs.first;
    final hub = ref.read(musicHubProvider);
    final api = hub.api(first.platform);
    if (api == null) return;
    final url = await api.getPlayUrl(first);
    final player = ref.read(playerServiceProvider);
    await player.playSong(
      Song(
        id: first.id,
        platform: first.platform,
        title: first.title,
        artist: first.artist,
        album: first.album,
        coverUrl: first.coverUrl,
        audioUrl: url,
        duration: first.duration,
        vip: first.vip,
        loginRequired: url == null,
      ),
      queue: [
        for (final s in _songs)
          Song(
            id: s.id,
            platform: s.platform,
            title: s.title,
            artist: s.artist,
            album: s.album,
            coverUrl: s.coverUrl,
            duration: s.duration,
            vip: s.vip,
          ),
      ],
    );
  }

  Future<void> _play(Song song) async {
    final hub = ref.read(musicHubProvider);
    final api = hub.api(song.platform);
    if (api == null) return;
    final url = await api.getPlayUrl(song);
    final player = ref.read(playerServiceProvider);
    await player.playSong(Song(
      id: song.id,
      platform: song.platform,
      title: song.title,
      artist: song.artist,
      album: song.album,
      coverUrl: song.coverUrl,
      audioUrl: url,
      duration: song.duration,
      vip: song.vip,
      loginRequired: url == null,
    ));
    if (url != null) {
      final lrc = await api.getLyrics(song);
      if (mounted) {
        ref
            .read(playerServiceProvider)
            .setLyrics(LyricParser.parseLrc(lrc));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    final p = widget.playlist;

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
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
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
                            '${p.creator} · ${p.songCount} 首',
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
                              child: Text(_error!,
                                  style: const TextStyle(
                                      color: Colors.redAccent)),
                            ),
                          )
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
            ],
          ),
        ),
      ),
    );
  }
}
