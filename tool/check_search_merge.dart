import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/models/track_group.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// 搜索聚合去重诊断（手动运行）：
///   dart run tool/check_search_merge.dart [关键词]
///
/// 验证：三平台各取 100 条 → 合并去重 → 打印曲目数与多音源曲目示例。
Future<void> main(List<String> args) async {
  final keyword = args.isNotEmpty ? args.first : '时间煮雨';
  final apis = [QQMusicApi(), NeteaseApi(), KuGouApi()];
  const names = ['QQ音乐', '网易云音乐', '酷狗音乐'];

  final all = <Song>[];
  for (final api in apis) {
    try {
      final songs = await api.searchSongs(keyword, size: 100);
      print('${names[api.platform]}: ${songs.length} 条');
      all.addAll(songs);
    } catch (e) {
      print('${names[api.platform]}: 搜索失败 $e');
    }
  }

  final groups = buildTrackGroups(all).take(100).toList();
  print('');
  print('合并原始条目: ${all.length} 条');
  print('去重后曲目: ${groups.length} 首（展示上限 100）');
  final multi = groups.where((g) => g.hasMultipleSources).toList();
  print('多平台音源曲目: ${multi.length} 首');
  for (final g in multi.take(5)) {
    final platforms = g.orderedSources.map((s) => names[s.platform]).join(' / ');
    print('  - ${g.title} - ${g.artist} → $platforms');
  }
  if (groups.isNotEmpty) {
    final first = groups.first;
    print('');
    print('首条示例: ${first.title} / ${first.artist} / '
        '音源数=${first.sources.length} / 首选=${names[first.primary.platform]}'
        '${first.allVip ? ' / 全部VIP' : ''}');
  }
}
