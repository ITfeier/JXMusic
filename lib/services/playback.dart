import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../providers.dart';

/// 统一播放入口：
/// - 本地歌曲直接用文件路径播放；
/// - 在线歌曲先解析播放直链再播放（跳转/续播等解析由 PlayerService 的 resolver 兜底）；
/// - 歌词由 PlayerService 的 lyricsResolver 自动加载，这里不再重复请求。
///
/// 返回 false 表示无法播放（无直链 / 需要登录 / 平台不支持）。
Future<bool> resolveAndPlay(
  WidgetRef ref,
  Song song, {
  List<Song>? queue,
}) async {
  final player = ref.read(playerServiceProvider);
  if (song.platform == JXPlatform.local) {
    await player.playSong(song, queue: queue);
    return true;
  }
  final api = ref.read(musicHubProvider).api(song.platform);
  if (api == null) return false;

  var url = song.audioUrl;
  if (url == null || url.isEmpty) {
    try {
      url = await api.getPlayUrl(song);
    } catch (_) {
      url = null;
    }
  }
  if (url == null || url.isEmpty) return false;

  final playable = song.copyWith(audioUrl: url);
  if (queue == null) {
    await player.playSong(playable);
  } else {
    await player.playSong(
      playable,
      queue: [
        for (final s in queue)
          if (s.globalId == song.globalId) playable else s,
      ],
    );
  }
  return true;
}
