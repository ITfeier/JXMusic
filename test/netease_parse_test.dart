import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/netease_api.dart';

/// 网易云搜索结果解析的回归测试（该接口 2026-11 已从 weapi 切到公开 GET 接口）。
void main() {
  test('公开接口字段：artists/album/duration(ms)/fee', () {
    final song = neteaseSongFromSearchJson({
      'id': 1857012586,
      'name': '国际歌',
      'artists': [
        {'name': '孙楠'},
        {'name': '周深'},
      ],
      'album': {'name': '国际歌', 'picUrl': 'http://p1.music.126.net/a.jpg'},
      'duration': 274000,
      'fee': 0,
    });
    expect(song, isNotNull);
    expect(song!.id, '1857012586');
    expect(song.title, '国际歌');
    expect(song.artist, '孙楠、周深');
    expect(song.album, '国际歌');
    expect(song.duration, 274);
    expect(song.coverUrl.startsWith('https://'), isTrue, reason: '封面统一升级 https');
    expect(song.vip, isFalse);
    expect(song.platform, 1);
  });

  test('weapi 字段兼容：ar/al/dt', () {
    final song = neteaseSongFromSearchJson({
      'id': 381962,
      'name': '国际歌',
      'ar': [
        {'name': '唐朝乐队'},
      ],
      'al': {'name': '摇滚中国乐势力', 'picUrl': '//p2.music.126.net/b.jpg'},
      'dt': 300500,
      'fee': 1,
    });
    expect(song, isNotNull);
    expect(song!.artist, '唐朝乐队');
    expect(song.duration, 300);
    expect(song.coverUrl.startsWith('https://'), isTrue);
    expect(song.vip, isTrue, reason: 'fee=1 是 VIP');
  });

  test('fee=8（非会员低音质可播）不算 VIP，保证能尝试播放', () {
    final song = neteaseSongFromSearchJson({
      'id': 5281551,
      'name': '国际歌',
      'artists': [
        {'name': '中央乐团合唱队'},
      ],
      'album': {'name': '国际歌'},
      'duration': 1000,
      'fee': 8,
    });
    expect(song!.vip, isFalse);
  });

  test('异常输入返回 null 不抛异常', () {
    expect(neteaseSongFromSearchJson(null), isNull);
    expect(neteaseSongFromSearchJson('x'), isNull);
    expect(neteaseSongFromSearchJson(<String, dynamic>{}), isNotNull);
  });
}
