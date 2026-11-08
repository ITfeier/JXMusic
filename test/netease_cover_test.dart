import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/api/netease_api.dart';

/// 网易云搜索「封面回填」的回归测试。
///
/// 背景：`/api/search/get/web` 的 album 只有 picId、没有 picUrl（2026-11 实测），
/// 导致 `Song.coverUrl` 为空、搜索/播放页全是渐变占位。修复方案是用
/// `/api/song/detail?ids=[...]` 批量补封面，回填逻辑抽成纯函数在这里锁回归。
Song _song(String id, {String coverUrl = ''}) => Song(
      id: id,
      platform: 1,
      title: '歌$id',
      artist: '歌手$id',
      coverUrl: coverUrl,
    );

void main() {
  group('neteaseCoversFromDetailJson（固定 JSON fixture）', () {
    test('解析 songs[].album.picUrl，http 统一升级 https，缺 picUrl 不产出', () {
      final fixture = {
        'code': 200,
        'songs': [
          {
            'id': 1001,
            'name': '歌1',
            'album': {
              'id': 1,
              'name': '专辑1',
              'picUrl': 'http://p1.music.126.net/a==/1.jpg',
            },
          },
          {
            'id': 1002,
            'name': '歌2',
            'album': {
              'id': 2,
              'name': '专辑2',
              'picUrl': 'https://p2.music.126.net/b==/2.jpg',
            },
          },
          {
            'id': 1003,
            'name': '歌3',
            'album': {'id': 3, 'name': '专辑3'},
          },
        ],
      };
      final covers = neteaseCoversFromDetailJson(fixture);
      expect(covers['1001'], 'https://p1.music.126.net/a==/1.jpg');
      expect(covers['1002'], 'https://p2.music.126.net/b==/2.jpg');
      expect(covers.containsKey('1003'), isFalse, reason: '没有 picUrl 就不产出');
    });

    test('兼容 weapi 的 al.picUrl / blurPicUrl 字段', () {
      final covers = neteaseCoversFromDetailJson({
        'songs': [
          {
            'id': 1,
            'al': {'blurPicUrl': '//p1.music.126.net/c==/3.jpg'},
          },
        ],
      });
      expect(covers['1'], 'https://p1.music.126.net/c==/3.jpg');
    });

    test('结构异常/null/非列表返回空映射，不抛异常', () {
      expect(neteaseCoversFromDetailJson(null), isEmpty);
      expect(neteaseCoversFromDetailJson('x'), isEmpty);
      expect(neteaseCoversFromDetailJson({'songs': 'bad'}), isEmpty);
      expect(neteaseCoversFromDetailJson({'songs': [1, 'x']}), isEmpty);
    });
  });

  group('neteaseFillMissingCovers（按 id 只回填空封面）', () {
    test('空 cover 被补、非空不覆盖、顺序与数量不变', () {
      final empty = _song('1001');
      final hasCover = _song('1002', coverUrl: 'https://keep/2.jpg');
      final covers = {
        '1001': 'https://p1.music.126.net/a==/1.jpg',
        '1002': 'https://p1.music.126.net/b==/2.jpg', // 不应覆盖已有封面
        '9999': 'https://p1.music.126.net/x==/x.jpg', // 不在结果里，忽略
      };

      final out = neteaseFillMissingCovers([empty, hasCover], covers);

      expect(out.length, 2);
      expect(out[0].id, '1001');
      expect(out[0].coverUrl, 'https://p1.music.126.net/a==/1.jpg');
      expect(out[1].coverUrl, 'https://keep/2.jpg', reason: '已有封面不得覆盖');
      expect(empty.coverUrl, isEmpty, reason: '不得修改入参 Song');
    });

    test('detail 失败（空映射）时原样返回：内容/顺序不变且不修改入参', () {
      final songs = [
        _song('1'),
        _song('2', coverUrl: 'https://keep/2.jpg'),
        _song('3'),
      ];

      final out = neteaseFillMissingCovers(songs, const {});

      expect(out.length, songs.length);
      for (var i = 0; i < songs.length; i++) {
        expect(out[i], same(songs[i]), reason: '失败时元素应原样返回');
      }
      expect(songs[0].coverUrl, isEmpty);
    });
  });

  group('neteaseCoverIdChunks（detail 单次 ≤100 个 id）', () {
    test('250 个 id 切成 100/100/50，去重并跳过空 id', () {
      final ids = <String>[
        for (var i = 0; i < 250; i++) '$i',
        '0', // 重复 id
        '', // 空 id
      ];
      final chunks = neteaseCoverIdChunks(ids);
      expect(chunks.length, 3);
      expect(chunks[0].length, 100);
      expect(chunks[1].length, 100);
      expect(chunks[2].length, 50);
      expect(chunks.expand((c) => c).length, 250);
    });

    test('没有需要补的 id 时返回空列表', () {
      expect(neteaseCoverIdChunks(const []), isEmpty);
      expect(neteaseCoverIdChunks(const ['', '']), isEmpty);
    });
  });
}
