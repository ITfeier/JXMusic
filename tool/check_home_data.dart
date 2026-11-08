import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// 首页数据诊断（手动运行）：
///   dart run tool/check_home_data.dart
///
/// 打印三个平台的「推荐歌单」「榜单歌曲」实际返回数量，用于排查首页只有几个歌单的问题。
Future<void> main() async {
  final apis = <MusicPlatformApi>[QQMusicApi(), NeteaseApi(), KuGouApi()];
  const names = <String>['QQ音乐', '网易云音乐', '酷狗音乐'];

  for (final api in apis) {
    final name = names[api.platform];
    print('');
    print('========== $name ==========');
    try {
      final playlists = await api.recommendPlaylists(size: 8);
      print('  推荐歌单: ${playlists.length} 个');
      for (final p in playlists.take(5)) {
        print('    - ${p.title}（${p.songCount} 首）id=${p.id} cover=${p.coverUrl.isNotEmpty}');
      }
    } catch (e) {
      print('  推荐歌单异常: $e');
    }
    try {
      final tops = await api.topSongs(size: 5);
      print('  榜单歌曲: ${tops.length} 首');
      for (final s in tops.take(3)) {
        print('    - ${s.title} / ${s.artist}（vip=${s.vip}）');
      }
    } catch (e) {
      print('  榜单异常: $e');
    }
  }
}
