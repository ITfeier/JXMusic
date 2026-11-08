import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';
import 'package:jxmusic/services/playback.dart';

/// 跨平台替代播放的联通性检查（需要联网，默认跳过）：
///   flutter test test/playback_fallback_test.dart --run-skipped
void main() {
  MusicApiHub buildHub() => MusicApiHub()
    ..register(QQMusicApi())
    ..register(NeteaseApi())
    ..register(KuGouApi());

  test('原平台 VIP/不可播时，能找到其它平台可播的免费版本', () async {
    final hub = buildHub();
    final qq = QQMusicApi();
    final results = await qq.searchSongs('卡农', size: 10);
    expect(results, isNotEmpty);

    // 优先挑一首 QQ 上 VIP 或本身解析不出直链的歌
    Song? target;
    for (final s in results) {
      final url = await qq.getPlayUrl(s);
      if (s.vip || url == null || url.isEmpty) {
        target = s;
        break;
      }
    }
    expect(target, isNotNull, reason: '没有找到不可播样本，接口可能变化');

    final alt = await findAlternativeSong(hub, target!, skipPlatform: 0);
    expect(alt, isNotNull, reason: '跨平台应能找到替代版本');
    expect(alt!.audioUrl, isNotNull);
    expect(alt.audioUrl!.isNotEmpty, isTrue);
    expect(alt.platform, isNot(JXPlatform.qq));
    // ignore: avoid_print
    print('替代结果: ${alt.displayPlatform} / ${alt.title} - ${alt.artist}');
  }, timeout: const Timeout(Duration(minutes: 2)), skip: '需要联网的替代播放联通性检查，按需 --run-skipped');

  test('网易云免费歌能解析出直链（搜索接口修复回归）', () async {
    final api = NeteaseApi();
    final songs = await api.searchSongs('卡农', size: 10);
    expect(songs, isNotEmpty, reason: '网易云搜索应返回结果');

    var resolved = 0;
    for (final s in songs.where((s) => !s.vip).take(3)) {
      final url = await api.getPlayUrl(s);
      if (url != null && url.isNotEmpty) resolved++;
    }
    expect(resolved, greaterThan(0), reason: '至少一首免费歌应能解析出直链');
  }, timeout: const Timeout(Duration(minutes: 2)), skip: '需要联网的网易云直链检查，按需 --run-skipped');
}
