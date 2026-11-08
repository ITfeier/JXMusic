import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../models/track_group.dart';
import '../providers.dart';
import '../services/playback.dart';
import 'glass.dart';
import 'layout.dart';

/// 聚合搜索页：三平台结果合并去重成一份列表（同一首歌不再重复出现），
/// 每首歌保留全部平台音源，播放页可切换音源。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  bool _searching = false;
  bool _searched = false;
  List<TrackGroup> _groups = const [];
  int _rawCount = 0;
  String _keyword = '';
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    setState(() {
      _keyword = kw;
      _searching = true;
      _searched = true;
      _groups = const [];
      _rawCount = 0;
      _error = null;
    });
    final hub = ref.read(musicHubProvider);

    // 三平台并行各取 100 条，合并后去重，最多展示 100 首
    final futures = <Future<List<Song>>>[
      for (final p in const [0, 1, 2])
        () async {
          final api = hub.api(p);
          if (api == null) return <Song>[];
          try {
            return await api
                .searchSongs(kw, size: 100)
                .timeout(const Duration(seconds: 15));
          } catch (_) {
            return <Song>[];
          }
        }(),
    ];
    final results = await Future.wait(futures);
    final all = results.expand((e) => e).toList();
    final groups = buildTrackGroups(all).take(100).toList();
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _rawCount = all.length;
      _searching = false;
      _error = all.isEmpty ? '三个平台都没有返回结果，请换个关键词或检查网络' : null;
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('「${group.title}」暂时无法播放：'
          '${JXPlatform.name(target.platform)} 音源不可用'
          '${group.hasMultipleSources ? '，可点其它平台标签再试' : ''}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: GlassCard(
            borderRadius: BorderRadius.circular(30),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: '搜索歌曲 / 歌手（三平台合并去重，最多 100 首）',
                hintStyle: const TextStyle(fontSize: 14),
                prefixIcon: const Icon(Icons.search_rounded,
                    size: 22, color: JXColors.primary),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 20),
                  onPressed: () {
                    _controller.clear();
                    setState(() {
                      _searched = false;
                      _groups = const [];
                      _rawCount = 0;
                      _error = null;
                    });
                  },
                ),
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
        if (_searched && !_searching && _groups.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Row(
              children: [
                Text(
                  '「$_keyword」· 去重后 ${_groups.length} 首',
                  style: TextStyle(fontSize: 11.5, color: textSub),
                ),
                if (_rawCount > _groups.length) ...[
                  const SizedBox(width: 6),
                  Text(
                    '（合并 $_rawCount 条音源）',
                    style: TextStyle(fontSize: 11, color: textSub),
                  ),
                ],
              ],
            ),
          ),
        Expanded(
          child: _searching
              ? const Center(
                  child:
                      CircularProgressIndicator(color: JXColors.primary))
              : !_searched
                  ? _SearchHints(onTap: (kw) {
                      _controller.text = kw;
                      _search(kw);
                    })
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(fontSize: 13, color: textSub),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding:
                              const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          itemCount: _groups.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final g = _groups[i];
                            return _TrackGroupRow(
                              group: g,
                              index: i,
                              onTap: () => _play(g),
                              onPlaySource: (source) =>
                                  _play(g, preferred: source),
                            );
                          },
                        ),
        ),
      ],
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
