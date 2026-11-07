import 'package:jxmusic/services/api/kugou_api.dart';

/// 酷狗歌单 + 播放链路连通性检查（手动运行）：
///   dart run tool/check_kugou_playlist.dart
Future<void> main() async {
  final api = KuGouApi();

  final lists = await api.recommendPlaylists(size: 5);
  print('推荐歌单：${lists.length} 个');
  for (final p in lists.take(3)) {
    print('  [${p.id}] ${p.title} / ${p.songCount} 首 / ${p.creator}');
    print('      封面 ${p.coverUrl}');
  }
  if (lists.isNotEmpty) {
    final songs = await api.playlistSongs(lists.first, page: 1, size: 5);
    print('歌单《${lists.first.title}》歌曲：${songs.length} 首');
    for (final s in songs.take(2)) {
      print('  ${s.title} / ${s.artist} / ${s.duration}s / vip=${s.vip}');
      print('      封面 ${s.coverUrl}');
    }
  }

  print('');
  print('=== 免费歌曲播放链路（搜索 -> 直链 -> 歌词） ===');
  final searched = await api.searchSongs('国际歌', size: 6);
  print('搜索结果：${searched.length} 首');
  final free = searched.where((s) => !s.vip).toList();
  print('其中免费可播：${free.length} 首');
  for (final s in free.take(1)) {
    final url = await api.getPlayUrl(s);
    print('  ${s.title} / ${s.artist}');
    print('  直链: ${url == null ? '解析失败' : url.substring(0, url.length > 90 ? 90 : url.length)}');
    final lrc = await api.getLyrics(s);
    print('  歌词长度: ${lrc.length}');
  }
}
