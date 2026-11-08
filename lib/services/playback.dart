import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../providers.dart';
import 'api/music_api.dart';

/// 切换音源的结果：成功/失败 + 可直接展示给用户的失败原因。
typedef SourceSwitchResult = ({bool ok, String? error});

/// 切换音源失败原因（纯函数，供 UI 与单测共用）。
///
/// 优先级：未登录且是 VIP 音源 → 提示先登录；接口层有具体错误 → 用它；
/// 否则给通用兜底（可能需要登录或受版权限制）。
String sourceSwitchError({
  required int platform,
  required bool vip,
  required bool loggedIn,
  String? apiError,
}) {
  final name = JXPlatform.name(platform);
  if (vip && !loggedIn) {
    return '需要先登录$name才能播放 VIP 音源';
  }
  final detail = apiError?.trim() ?? '';
  if (detail.isNotEmpty) return detail;
  return '$name 音源不可用（可能需要登录或受版权限制）';
}

/// 音源面板的这一行是否可点：当前正在播放的音源不可点。
bool canSwitchToSource(Song source, Song? current) =>
    current == null || source.globalId != current.globalId;

/// 切源 await 前后是否仍在同一播放上下文（同一首歌 + 同一队列索引）。
///
/// 解析直链/打开媒体都是网络或 IO await，期间按 N/P、托盘切歌、自然播完自动
/// 下一首都会改 currentSong/currentIndex；抽成纯函数便于单测，也用于取消本次
/// 音源替换与旧进度 seek（否则会把旧曲目音源替换到新曲目上）。
bool samePlaybackContext({
  required Song? now,
  required int nowIndex,
  required String startedGlobalId,
  required int startedIndex,
}) =>
    now != null &&
    now.globalId == startedGlobalId &&
    nowIndex == startedIndex;

/// 只采用本次请求新产生的 `lastError`（L-1）。
///
/// 平台 API 的 lastError 只在扫码链路写入、`getPlayUrl` 不清理，直接读会把上一次
/// 扫码失败的陈旧错误带进音源面板；请求前后快照一致则视为本次无接口错误。
String? freshApiError(String? before, String? after) =>
    after != before ? after : null;

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

/// 播放中切换音源：保持当前播放进度，并把当前队列项替换为目标音源。
///
/// 切换失败时**不改变当前播放**（不做跨平台静默换歌），返回具体失败原因；
/// 成功后 `player.currentSong` 即目标音源、队列长度与索引不变。
///
/// 竞态保护（M-1）：解析直链是网络 await，期间用户按 N/P、托盘切歌或自动下一首
/// 都可能已经换歌；回来若发现当前曲目/索引已变，直接失败返回，不替换队列项、
/// 不 seek 旧进度，避免把旧曲目的目标音源替换到新曲目上。
Future<SourceSwitchResult> switchSource(WidgetRef ref, Song source) async {
  final player = ref.read(playerServiceProvider);
  final current = player.currentSong;
  if (current == null) {
    return (ok: false, error: '当前没有正在播放的歌曲');
  }
  // 当前音源本身不可点（防御：UI 已禁用当前行）
  if (!canSwitchToSource(source, current)) {
    return (ok: true, error: null);
  }

  final startedGlobalId = current.globalId;
  final startedIndex = player.currentIndex;
  final position = player.position;
  final sources = player.currentSources;
  final hub = ref.read(musicHubProvider);
  final api = hub.api(source.platform);
  final loggedIn = ref.read(accountProvider(source.platform)) != null;

  if (api == null) {
    return (
      ok: false,
      error: sourceSwitchError(
        platform: source.platform,
        vip: source.vip,
        loggedIn: loggedIn,
        apiError: null,
      ),
    );
  }

  var url = source.audioUrl;
  String? apiError;
  if (url == null || url.isEmpty) {
    final before = api.lastError;
    try {
      url = await api.getPlayUrl(source);
    } catch (_) {
      url = null;
    }
    apiError = freshApiError(before, api.lastError);
  }

  // 解析期间可能已经换歌：此时不能替换当前队列项，也不能 seek 旧进度。
  if (!samePlaybackContext(
    now: player.currentSong,
    nowIndex: player.currentIndex,
    startedGlobalId: startedGlobalId,
    startedIndex: startedIndex,
  )) {
    return (ok: false, error: '播放已切换，请重试');
  }

  if (url == null || url.isEmpty) {
    return (
      ok: false,
      error: sourceSwitchError(
        platform: source.platform,
        vip: source.vip,
        loggedIn: loggedIn,
        apiError: apiError,
      ),
    );
  }

  await player.playSong(
    source.copyWith(audioUrl: url),
    sources: sources.isEmpty ? <Song>[source] : sources,
    replaceCurrent: true,
  );
  // open 期间也可能被再次切歌：不 seek，避免把旧进度 seek 到新曲目上。
  if (!samePlaybackContext(
    now: player.currentSong,
    nowIndex: player.currentIndex,
    startedGlobalId: source.globalId,
    startedIndex: startedIndex,
  )) {
    return (ok: false, error: '播放已切换，请重试');
  }
  if (position > Duration.zero) {
    await player.seek(position);
  }
  return (ok: true, error: null);
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
