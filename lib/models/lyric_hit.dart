import 'song.dart';

/// 歌词搜索命中：命中的歌曲 + 歌词片段
class LyricHit {
  final Song song;
  final String snippet; // 命中的歌词片段（高亮展示用）

  const LyricHit({required this.song, this.snippet = ''});
}
