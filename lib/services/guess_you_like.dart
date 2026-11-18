import 'dart:math';

import '../models/song.dart';
import 'library_store.dart';

/// 猜你喜欢推荐器：播放历史 + 收藏的口味画像，配每日固定随机种子。
///
/// 推荐链路（首页区块）：
/// 1. [tasteArtists] 从播放历史/收藏统计高频歌手（收藏权重 ×2）；
/// 2. 首页按口味歌手轮换平台搜索候选池（排除已听、去重）；
/// 3. [picks] 用「日期种子 ×1000 + 换一批批次」洗牌取样 —— 同一天同一批
///    结果稳定，点「换一批」批次 +1 换一批新歌，隔天种子变化自动换推荐。
class GuessYouLike {
  /// 每日种子：2026-11-17 -> 20261117。同一天推荐稳定，隔天自动换一批。
  static int dailySeed(DateTime now) =>
      now.year * 10000 + now.month * 100 + now.day;

  /// 拆分歌手名：「周杰伦/费玉清」「周杰伦、林俊杰」「A feat. B」-> 多人；
  /// 过滤空串与无口味意义的占位名（群星/未知/各种艺术家…）。
  static List<String> splitArtists(String artist) {
    return artist
        .split(RegExp(r'[/、,，&+]|\sfeat\.?\s|\bft\b', caseSensitive: false))
        .map((s) => s.trim())
        .where((s) =>
            s.isNotEmpty &&
            !const {'群星', '未知', '未知歌手', '各种艺术家', '未知艺术家'}
                .contains(s))
        .toList();
  }

  /// 口味画像：按得分降序的歌手名列表。
  /// 历史每播一次计 1 分，收藏每首计 2 分（收藏是更强的口味信号）；
  /// 同分按名字升序排序，保证结果稳定可测。
  static List<String> tasteArtists(
    List<HistoryEntry> history,
    List<Song> favorites, {
    int maxArtists = 6,
  }) {
    final scores = <String, int>{};
    void score(String name, int weight) {
      scores[name] = (scores[name] ?? 0) + weight;
    }

    for (final entry in history) {
      for (final name in splitArtists(entry.song.artist)) {
        score(name, 1);
      }
    }
    for (final song in favorites) {
      for (final name in splitArtists(song.artist)) {
        score(name, 2);
      }
    }
    final ranked = scores.entries.toList()
      ..sort((a, b) {
        final byScore = b.value.compareTo(a.value);
        return byScore != 0 ? byScore : a.key.compareTo(b.key);
      });
    return [for (final e in ranked.take(maxArtists)) e.key];
  }

  /// 固定种子洗牌（Fisher-Yates）：同一种子顺序完全一致，可复现可测；
  /// 不修改传入的原列表。
  static List<T> dailyShuffle<T>(List<T> list, int seed) {
    final out = List<T>.of(list);
    final random = Random(seed);
    for (var i = out.length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final tmp = out[i];
      out[i] = out[j];
      out[j] = tmp;
    }
    return out;
  }

  /// 当日推荐取样：种子 = 日期种子 ×1000 + 批次（[batch] 由「换一批」递增）。
  /// 空池返回空列表（首页区块整体隐藏）。
  static List<Song> picks(
    List<Song> pool,
    DateTime now,
    int batch, {
    int take = 9,
  }) {
    if (pool.isEmpty) return const [];
    return dailyShuffle(pool, dailySeed(now) * 1000 + batch)
        .take(take)
        .toList();
  }
}
