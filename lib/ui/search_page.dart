import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/playback.dart';
import 'glass.dart';

/// 聚合搜索页
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final Map<int, List<Song>> _results = {};
  bool _searching = false;
  bool _searched = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    setState(() {
      _searching = true;
      _searched = true;
      _results.clear();
    });
    final hub = ref.read(musicHubProvider);

    await Future.wait([
      for (final p in const [0, 1, 2])
        () async {
          final api = hub.api(p);
          if (api == null) return;
          final songs = await api.searchSongs(kw, size: 15);
          if (mounted) setState(() => _results[p] = songs);
        }(),
    ]);
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _play(Song song) async {
    final ok = await resolveAndPlay(ref, song);
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(song.vip
          ? '「${song.title}」为 VIP 歌曲，请先登录对应平台后播放'
          : '获取「${song.title}」播放链接失败，请重试'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 搜索框
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: GlassCard(
            borderRadius: BorderRadius.circular(30),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: '搜索歌曲 / 歌手（聚合QQ/酷狗/网易云）',
                hintStyle: const TextStyle(fontSize: 14),
                prefixIcon: const Icon(Icons.search_rounded,
                    size: 22, color: JXColors.primary),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 20),
                  onPressed: () {
                    _controller.clear();
                    setState(() {
                      _searched = false;
                      _results.clear();
                    });
                  },
                ),
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
        // 结果区
        Expanded(
          child: _searching
              ? const Center(
                  child: CircularProgressIndicator(color: JXColors.primary))
              : !_searched
                  ? _SearchHint(
                      onTapKeyword: (kw) {
                        _controller.text = kw;
                        _search(kw);
                      },
                    )
                  : _Results(
                      results: _results,
                      onPlay: _play,
                    ),
        ),
      ],
    );
  }
}

/// 未搜索时的推荐词
class _SearchHint extends StatelessWidget {
  final void Function(String) onTapKeyword;
  const _SearchHint({required this.onTapKeyword});

  static const _keywords = [
    '周杰伦',
    '陈奕迅',
    '林俊杰',
    '民谣',
    '治愈',
    '电子',
    '摇滚',
    '粤语',
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.travel_explore_rounded,
                size: 56, color: textSub.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text('试试搜索', style: TextStyle(color: textSub, fontSize: 14)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                for (final kw in _keywords)
                  GestureDetector(
                    onTap: () => onTapKeyword(kw),
                    child: Chip(
                      label: Text(kw),
                      backgroundColor: Colors.transparent,
                      side: BorderSide(color: textSub.withValues(alpha: 0.3)),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索结果（三平台分块）
class _Results extends StatelessWidget {
  final Map<int, List<Song>> results;
  final void Function(Song) onPlay;

  const _Results({required this.results, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final hasAny = results.values.any((l) => l.isNotEmpty);
    if (!hasAny) {
      return const Center(
        child: Text('没有找到结果，换个关键词试试',
            style: TextStyle(fontSize: 14, color: Colors.grey)),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        for (final p in const [0, 1, 2])
          if (results[p]?.isNotEmpty ?? false) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: JXPlatform.color(p),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    JXPlatform.name(p),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '  ${results[p]!.length} 首',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            _PlatformSongList(songs: results[p]!, onPlay: onPlay),
          ],
      ],
    );
  }
}

class _PlatformSongList extends StatelessWidget {
  final List<Song> songs;
  final void Function(Song) onPlay;

  const _PlatformSongList({required this.songs, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return Column(
      children: [
        for (final s in songs)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: GlassCover(url: s.coverUrl, size: 44,
                borderRadius: BorderRadius.circular(10)),
            title: Text(
              s.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: textColor),
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
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                  onPressed: () => onPlay(s),
                ),
              ],
            ),
            onTap: () => onPlay(s),
          ),
      ],
    );
  }
}
