import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// 联网探针（手动运行）：
///   D:\Programs\flutter\bin\dart.bat run tool/check_playlist_paging.dart
///
/// 验证三平台 recommendPlaylists 的分页有效：page=2 的标题应与 page=1 不同。
/// 若某平台 page2 与 page1 相同（或为空），「全部歌单」页滑到底会加载不到新歌单。
Future<void> main() async {
  final apis = <MusicPlatformApi>[QQMusicApi(), NeteaseApi(), KuGouApi()];
  const names = <String>['QQ音乐', '网易云音乐', '酷狗音乐'];
  var allOk = true;

  for (final api in apis) {
    final name = names[api.platform];
    print('');
    print('========== $name ==========');
    try {
      final page1 = await api.recommendPlaylists(page: 1, size: 20);
      final page2 = await api.recommendPlaylists(page: 2, size: 20);
      _printPage('page1', page1);
      _printPage('page2', page2);
      if (page1.isEmpty || page2.isEmpty) {
        print('结果: FAIL（存在空页，分页可能失效）');
        allOk = false;
        continue;
      }
      final ids1 = page1.map((p) => p.id).toSet();
      final ids2 = page2.map((p) => p.id).toSet();
      final idOverlap = ids1.intersection(ids2).length;
      final titles1 = page1.map((p) => p.title).toSet();
      final titles2 = page2.map((p) => p.title).toSet();
      final titleOverlap = titles1.intersection(titles2).length;
      final differ = idOverlap < ids1.length || titleOverlap < page1.length;
      print('id 重叠: $idOverlap/${ids1.length}；标题重叠: $titleOverlap/${page1.length}');
      print('结果: ${differ ? 'PASS（page2 ≠ page1）' : 'FAIL（page2 与 page1 完全相同）'}');
      if (!differ) allOk = false;
    } catch (e) {
      print('异常: $e');
      allOk = false;
    }
  }

  print('');
  print(allOk ? '全部平台分页探针通过' : '存在平台分页异常，请检查上方输出');
}

void _printPage(String label, List<Playlist> playlists) {
  print('$label: ${playlists.length} 个');
  for (final p in playlists.take(3)) {
    print('  - ${p.title}（id=${p.id}）');
  }
}
