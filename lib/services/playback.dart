import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../providers.dart';
import 'api/music_api.dart';

/// 统一播放入口：
/// - 本地歌曲直接用文件路径播放；
/// - 在线歌曲先解析播放直链再播放（跳转/续播等解析由 PlayerService 的 resolver 兜底）；
/// - **当前平台拿不到直链时，自动到其它平台找同名同歌手的免费版本替代播放**
///   （VIP/版权限制是平台维度的，换个平台经常就能听）；
/// - 歌词由 PlayerService 的 lyricsResolver 自动加载，这里不再重复请求。
///
/// 返回 false 表示所有平台都无法播放（无直链 / 需要登录 / 平台不支持）。
Future<bool> resolveAndPlay(
  WidgetRef ref,
  Song song, {
  List<Song>? queue,
  List<Song>? sources,
  bool allowCrossPlatformFallback = true,
}) async {
  final player = ref.read(playerServiceProvider);
  if (song.platform == JXPlatform.local) {
    await player.playSong(song, queue: queue, sources: sources);
    return true;
  }
  final hub = ref.read(musicHubProvider);
  final api = hub.api(song.platform);

  var playable = song;
  var url = song.audioUrl;
  if ((url == null || url.isEmpty) && api != null) {
    try {
      url = await api.getPlayUrl(song);
    } catch (_) {
      url = null;
    }
  }

  // 本平台不可播 → 跨平台找免费替代（原始歌曲是 VIP / 版权限制时最常见）。
  // 由用户明确点了某个音源/某首歌时（allowCrossPlatformFallback=false）不做静默替代，
  // 保证"播的就是你点的那一首、那个平台"。
  if ((url == null || url.isEmpty) && allowCrossPlatformFallback) {
    final alt = await findAlternativeSong(hub, song,
        skipPlatform: song.platform);
    if (alt == null) return false;
    playable = alt;
    url = alt.audioUrl;
    debugPrint('[JXMusic] 「${song.title}」在原平台不可播，已切换 '
        '${playable.displayPlatform} 同名版本');
  }
  if (url == null || url.isEmpty) return false;

  playable = playable.copyWith(audioUrl: url);
  if (queue == null) {
    await player.playSong(playable, sources: sources);
  } else {
    await player.playSong(
      playable,
      queue: [
        for (final s in queue)
          if (s.globalId == song.globalId) playable else s,
      ],
      sources: sources,
    );
  }
  return true;
}

/// 播放聚合曲目：先试「首选音源」（与列表里标注的一致），失败再依次试其它平台音源。
/// 不做跨平台"换一首同名歌"的静默替代，失败就返回 false 由 UI 明确提示。
Future<bool> playTrackGroup(
  WidgetRef ref,
  List<Song> sources, {
  Song? preferred,
}) async {
  if (sources.isEmpty) return false;
  final first = preferred ?? sources.first;
  final ordered = <Song>[
    first,
    for (final s in sources)
      if (s.globalId != first.globalId) s,
  ];
  for (final source in ordered) {
    if (await resolveAndPlay(
      ref,
      source,
      sources: sources,
      allowCrossPlatformFallback: false,
    )) {
      return true;
    }
  }
  return false;
}

/// 直接播放指定平台的音源（用户点列表里的平台标签时用）。
Future<bool> playSingleSource(
  WidgetRef ref,
  Song source, {
  List<Song>? sources,
}) {
  return resolveAndPlay(
    ref,
    source,
    sources: sources ?? <Song>[source],
    allowCrossPlatformFallback: false,
  );
}

/// 播放中切换音源：保持当前播放进度。
Future<bool> switchSource(WidgetRef ref, Song source) async {
  final player = ref.read(playerServiceProvider);
  final position = player.position;
  final sources = player.currentSources;
  final ok = await resolveAndPlay(
    ref,
    source,
    sources: sources.isEmpty ? <Song>[source] : sources,
    allowCrossPlatformFallback: false,
  );
  if (ok && position > Duration.zero) {
    await player.seek(position);
  }
  return ok;
}

/// 在其它平台搜索同名/同歌手歌曲，返回第一个能解析出直链的免费版本。
///
/// 抽成独立函数（接收 [MusicApiHub] 而不是 ref）便于单独测试。
Future<Song?> findAlternativeSong(
  MusicApiHub hub,
  Song song, {
  required int skipPlatform,
}) async {
  final title = song.title.trim();
  if (title.isEmpty) return null;
  // 去掉常见的括号补充信息（现场版/伴奏等），提高匹配率
  final baseTitle = title
      .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
      .trim();
  final artist = song.artist.split('、').first.trim();

  for (final platform in const [
    JXPlatform.qq,
    JXPlatform.netease,
    JXPlatform.kugou,
  ]) {
    if (platform == skipPlatform) continue;
    final api = hub.api(platform);
    if (api == null) continue;
    try {
      final results = await api
          .searchSongs('${baseTitle.isEmpty ? title : baseTitle} $artist',
              size: 5)
          .timeout(const Duration(seconds: 8));
      for (final candidate in results) {
        if (candidate.vip) continue; // 优先免费版本，避免再撞登录墙
        if (!_similarTitle(candidate.title, title)) continue;
        try {
          final url = await api
              .getPlayUrl(candidate)
              .timeout(const Duration(seconds: 8));
          if (url != null && url.isNotEmpty) {
            return candidate.copyWith(audioUrl: url);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }
  return null;
}

/// 标题相似度：归一化后互相包含即可（容忍前后缀、大小写、标点差异）
bool _similarTitle(String a, String b) {
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '');
  final na = norm(a);
  final nb = norm(b);
  if (na.isEmpty || nb.isEmpty) return false;
  return na.contains(nb) || nb.contains(na);
}
