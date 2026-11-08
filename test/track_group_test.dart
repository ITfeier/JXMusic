import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/models/track_group.dart';

Song song({
  required int platform,
  required String title,
  required String artist,
  bool vip = false,
  String cover = '',
  int duration = 200,
  String? id,
}) {
  return Song(
    id: id ?? '$platform-$title-$artist',
    platform: platform,
    title: title,
    artist: artist,
    coverUrl: cover,
    duration: duration,
    vip: vip,
  );
}

void main() {
  test('同一首歌在三个平台出现 → 合并为一个曲目、三个音源', () {
    final groups = buildTrackGroups([
      song(platform: 0, title: '时间煮雨', artist: '郁可唯'),
      song(platform: 1, title: '时间煮雨', artist: '郁可唯'),
      song(platform: 2, title: '时间煮雨', artist: '郁可唯'),
    ]);
    expect(groups.length, 1);
    expect(groups.single.sources.length, 3);
    expect(groups.single.hasMultipleSources, isTrue);
    expect(groups.single.orderedSources.map((s) => s.platform).toList(),
        [0, 1, 2]);
  });

  test('不同版本（钢琴版/光遇版）保留为独立曲目', () {
    final groups = buildTrackGroups([
      song(platform: 0, title: '时间煮雨', artist: '郁可唯'),
      song(platform: 0, title: '时间煮雨（钢琴版）', artist: '柳轻颂'),
      song(platform: 1, title: '时间煮雨(光遇版)', artist: '顾行'),
    ]);
    expect(groups.length, 3);
  });

  test('去重时忽略空格/标点/大小写差异', () {
    final groups = buildTrackGroups([
      song(platform: 0, title: 'Hello, World!', artist: 'Adele'),
      song(platform: 1, title: 'hello world', artist: 'adele'),
    ]);
    expect(groups.length, 1);
    expect(groups.single.sources.length, 2);
  });

  test('同平台重复结果只保留一条音源', () {
    final groups = buildTrackGroups([
      song(platform: 0, title: '卡农', artist: 'X', id: 'a'),
      song(platform: 0, title: '卡农', artist: 'X', id: 'b'),
    ]);
    expect(groups.length, 1);
    expect(groups.single.sources.length, 1);
  });

  test('首选音源优先非 VIP，且优先有封面/时长', () {
    final groups = buildTrackGroups([
      song(platform: 0, title: '晴天', artist: '周杰伦', vip: true),
      song(platform: 1, title: '晴天', artist: '周杰伦', vip: false),
      song(
          platform: 2,
          title: '晴天',
          artist: '周杰伦',
          vip: false,
          cover: 'https://x/y.jpg',
          duration: 300),
    ]);
    final g = groups.single;
    expect(g.allVip, isFalse);
    expect(g.primary.vip, isFalse);
    expect(g.primary.platform, JXPlatform.kugou, reason: '非 VIP 中有封面的优先');
  });

  test('全部 VIP 时 allVip 为 true，primary 仍可用', () {
    final groups = buildTrackGroups([
      song(platform: 0, title: 'VIP歌', artist: 'X', vip: true),
      song(platform: 1, title: 'VIP歌', artist: 'X', vip: true),
    ]);
    expect(groups.single.allVip, isTrue);
    expect(groups.single.primary.title, 'VIP歌');
  });

  test('空标题被跳过，顺序按首次出现', () {
    final groups = buildTrackGroups([
      song(platform: 0, title: '  ', artist: 'X'),
      song(platform: 0, title: 'B曲', artist: 'X'),
      song(platform: 1, title: 'A曲', artist: 'X'),
      song(platform: 2, title: 'B曲', artist: 'X'),
    ]);
    expect(groups.map((g) => g.title).toList(), ['B曲', 'A曲']);
    expect(groups.first.sources.length, 2);
  });
}
