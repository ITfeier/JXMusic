import 'song.dart';

/// 跨平台聚合后的一首「曲目」：同一首歌在不同平台的音源合并到 [sources] 里。
class TrackGroup {
  final String key;
  final String title;
  final String artist;
  final String album;
  final String coverUrl;
  final int duration;

  /// 各平台音源（至少 1 个），顺序与平台枚举一致
  final List<Song> sources;

  const TrackGroup({
    required this.key,
    required this.title,
    required this.artist,
    required this.album,
    required this.coverUrl,
    required this.duration,
    required this.sources,
  });

  bool get hasMultipleSources => sources.length > 1;

  /// 是否所有音源都是 VIP（这类曲目不登录基本放不了）
  bool get allVip => sources.every((s) => s.vip);

  /// 首选音源：非 VIP 优先，其次时长/封面更完整的
  Song get primary {
    final free = sources.where((s) => !s.vip).toList();
    final pool = free.isEmpty ? [...sources] : free;
    pool.sort((a, b) {
      final coverA = a.coverUrl.isNotEmpty ? 1 : 0;
      final coverB = b.coverUrl.isNotEmpty ? 1 : 0;
      if (coverA != coverB) return coverB - coverA;
      return b.duration - a.duration;
    });
    return pool.first;
  }

  /// 按平台顺序列出音源（用于播放页切换按钮）
  List<Song> get orderedSources => [...sources]
    ..sort((a, b) => a.platform.compareTo(b.platform));
}

String _normKey(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll(RegExp(r'[\\/:*?"<>|,，.。!！?？·・、_\-—–~()（）\[\]【】]'), '')
    .trim();

/// 把多平台搜索结果合并为去重后的曲目列表。
///
/// 去重依据：归一化后的「歌名 + 歌手」。不同版本（钢琴版/光遇版等）标题不同，
/// 会保留为不同曲目；同一版本在多个平台出现则合并成一个 [TrackGroup]。
List<TrackGroup> buildTrackGroups(Iterable<Song> songs) {
  final map = <String, TrackGroup>{};
  final order = <String>[];

  for (final song in songs) {
    final title = song.title.trim();
    if (title.isEmpty) continue;
    final artist = song.artist.trim();
    final key = '${_normKey(title)}|${_normKey(artist)}';

    final existing = map[key];
    if (existing == null) {
      map[key] = TrackGroup(
        key: key,
        title: title,
        artist: artist,
        album: song.album,
        coverUrl: song.coverUrl,
        duration: song.duration,
        sources: [song],
      );
      order.add(key);
      continue;
    }

    // 去重同平台重复项后追加音源
    final sources = [...existing.sources];
    sources.removeWhere((s) => s.platform == song.platform);
    sources.add(song);

    map[key] = TrackGroup(
      key: key,
      title: existing.title,
      artist: existing.artist,
      // 用信息更完整的那份元数据
      album: existing.album.isNotEmpty ? existing.album : song.album,
      coverUrl:
          existing.coverUrl.isNotEmpty ? existing.coverUrl : song.coverUrl,
      duration: existing.duration > 0 ? existing.duration : song.duration,
      sources: sources,
    );
  }

  return [for (final k in order) map[k]!];
}
