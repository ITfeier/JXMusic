import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/playback.dart';
import 'package:jxmusic/services/player_service.dart';

/// 播放页「切换音源」链路的测试：
/// - `replaceCurrentInQueue`：切源只替换当前队列项（队列长度/索引不变）；
/// - `PlayerService.playSong(replaceCurrent: true)` 的接法（回归：级联先 clear
///   再求值会清空队列——只有一个纯函数测试是发现不了的，必须测到 playSong）；
/// - `sourceSwitchError`：失败原因优先级（未登录 VIP → lastError → 兜底）；
/// - `canSwitchToSource`：当前音源行不可点。
Song _song({
  required String id,
  required int platform,
  bool vip = false,
  String? audioUrl,
}) =>
    Song(
      id: id,
      platform: platform,
      title: '歌$id',
      artist: '歌手$id',
      vip: vip,
      audioUrl: audioUrl,
    );

void main() {
  group('replaceCurrentInQueue：切源只替换当前项', () {
    test('替换后队列长度不变、索引不变、其它项原样保留、入参不被修改', () {
      final a = _song(id: 'a', platform: JXPlatform.qq);
      final b = _song(id: 'b', platform: JXPlatform.netease);
      final c = _song(id: 'c', platform: JXPlatform.kugou);
      final queue = <Song>[a, b, c];
      const currentIndex = 1;
      final target = _song(id: 'b', platform: JXPlatform.kugou);

      final result = replaceCurrentInQueue(
        queue: queue,
        currentIndex: currentIndex,
        song: target,
      );

      expect(result.queue.length, 3, reason: '队列长度必须不变');
      expect(result.index, 1, reason: '索引不变');
      expect(result.queue[currentIndex].globalId, target.globalId,
          reason: '当前位置应变成目标音源');
      expect(result.queue[currentIndex].platform, JXPlatform.kugou);
      expect(result.queue[0], same(a));
      expect(result.queue[2], same(c));
      // 入参列表不被修改
      expect(queue[currentIndex], same(b));
    });

    test('越界索引：返回等长副本、索引原样返回、不抛异常', () {
      final queue = <Song>[
        _song(id: 'a', platform: JXPlatform.qq),
        _song(id: 'b', platform: JXPlatform.kugou),
      ];
      final replacement = _song(id: 'x', platform: JXPlatform.netease);

      expect(
        () => replaceCurrentInQueue(
            queue: queue, currentIndex: -1, song: replacement),
        returnsNormally,
      );
      expect(
        () => replaceCurrentInQueue(
            queue: queue, currentIndex: 2, song: replacement),
        returnsNormally,
      );
      final negative = replaceCurrentInQueue(
          queue: queue, currentIndex: -1, song: replacement);
      final overflow = replaceCurrentInQueue(
          queue: queue, currentIndex: 2, song: replacement);
      expect(negative.queue.length, 2);
      expect(negative.index, -1);
      expect(overflow.queue.length, 2);
      expect(overflow.index, 2);
      expect(negative.queue[0].globalId, queue[0].globalId);
      expect(overflow.queue[1].globalId, queue[1].globalId);
      expect(overflow.queue, isNot(same(queue)));
    });

    test('同一首歌替换（globalId 不变、audioUrl 更新）：长度仍不变', () {
      final queue = <Song>[
        _song(id: 'x', platform: JXPlatform.qq),
        _song(id: 'y', platform: JXPlatform.kugou),
      ];
      final updated = _song(
        id: 'x',
        platform: JXPlatform.qq,
        audioUrl: 'https://cdn.example.com/x.mp3',
      );

      final result = replaceCurrentInQueue(
          queue: queue, currentIndex: 0, song: updated);

      expect(result.queue.length, 2);
      expect(result.index, 0);
      expect(result.queue[0].globalId, '0:x');
      expect(result.queue[0].audioUrl, 'https://cdn.example.com/x.mp3');
      expect(result.queue[1], same(queue[1]));
    });
  });

  group('playSong(replaceCurrent: true)：切源接法回归', () {
    test('切源后队列不清空、长度/索引不变、当前项为目标音源', () async {
      final service = PlayerService(initPlayer: false);
      addTearDown(service.dispose);

      final a = _song(id: 'a', platform: JXPlatform.qq);
      final b = _song(id: 'b', platform: JXPlatform.netease);
      final c = _song(id: 'c', platform: JXPlatform.kugou);

      // 构造队列 [a, b, c]，当前播放 b（索引 1）
      await service.playSong(b, queue: <Song>[a, b, c]);
      expect(service.queue.length, 3);
      expect(service.currentIndex, 1);

      // 切到酷狗音源 b'：只替换索引 1 处的对象
      final target = _song(
          id: 'b', platform: JXPlatform.kugou, audioUrl: 'https://cdn/b.mp3');
      await service.playSong(
        target,
        sources: <Song>[a, target],
        replaceCurrent: true,
      );

      // 回归断言：修复前 `..clear()..addAll(replace(_queue))` 会读到已清空的
      // 队列 → 这里 length 变成 0、currentSong 变 null。
      expect(service.queue.length, 3, reason: '切源不得清空/缩短队列');
      expect(service.currentIndex, 1, reason: '当前索引必须保持不变');
      expect(service.currentSong?.globalId, target.globalId,
          reason: 'currentSong 必须变成目标音源');
      expect(service.queue[1].platform, JXPlatform.kugou);
      expect(service.queue[0], same(a));
      expect(service.queue[2], same(c));
    });

    test('空队列/越界索引时 replaceCurrent 退回普通播放逻辑（不崩、能入队）',
        () async {
      final service = PlayerService(initPlayer: false);
      addTearDown(service.dispose);

      final song = _song(id: 'x', platform: JXPlatform.qq);
      service.clearQueue();
      await service.playSong(song, replaceCurrent: true);

      expect(service.queue.length, 1);
      expect(service.currentIndex, 0);
      expect(service.currentSong?.globalId, song.globalId);
    });
  });

  group('sourceSwitchError：失败原因优先级', () {
    test('未登录 + VIP：先登录提示优先于 apiError', () {
      final message = sourceSwitchError(
        platform: JXPlatform.qq,
        vip: true,
        loggedIn: false,
        apiError: '接口层错误',
      );
      expect(message, contains('需要先登录'));
      expect(message, contains('QQ音乐'));
      expect(message, contains('VIP'));
      expect(message, isNot(contains('接口层错误')));
    });

    test('已登录 + VIP 且有 apiError：使用接口层具体原因', () {
      final message = sourceSwitchError(
        platform: JXPlatform.kugou,
        vip: true,
        loggedIn: true,
        apiError: '酷狗登录态已失效，请重新扫码',
      );
      expect(message, '酷狗登录态已失效，请重新扫码');
    });

    test('无 apiError：兜底文案包含平台名与版权/登录提示', () {
      final message = sourceSwitchError(
        platform: JXPlatform.netease,
        vip: false,
        loggedIn: false,
        apiError: null,
      );
      expect(message, contains('网易云音乐'));
      expect(message, contains('音源不可用'));
      expect(message, contains('版权'));
    });

    test('apiError 为空白串时按无错误处理（不展示空白原因）', () {
      final message = sourceSwitchError(
        platform: JXPlatform.qq,
        vip: false,
        loggedIn: false,
        apiError: '   ',
      );
      expect(message, contains('音源不可用'));
      expect(message.trim(), isNotEmpty);
    });
  });

  group('canSwitchToSource：当前音源行不可点', () {
    test('当前音源返回 false，其它音源/无播放时返回 true', () {
      final current = _song(id: 'x', platform: JXPlatform.qq);
      final other = _song(id: 'y', platform: JXPlatform.kugou);

      expect(canSwitchToSource(current, current), isFalse);
      expect(canSwitchToSource(current, other), isTrue);
      expect(canSwitchToSource(current, null), isTrue);
    });
  });

  group('samePlaybackContext：切源 await 期间换歌竞态（M-1）', () {
    test('同一首歌且同一索引 → true', () {
      final song = _song(id: 'x', platform: JXPlatform.qq);
      expect(
        samePlaybackContext(
          now: song,
          nowIndex: 2,
          startedGlobalId: '0:x',
          startedIndex: 2,
        ),
        isTrue,
      );
    });

    test('曲目被换/索引被改/已无播放 → false（取消替换与进度 seek）', () {
      final song = _song(id: 'x', platform: JXPlatform.qq);
      final other = _song(id: 'y', platform: JXPlatform.kugou);
      expect(
        samePlaybackContext(
          now: other,
          nowIndex: 2,
          startedGlobalId: '0:x',
          startedIndex: 2,
        ),
        isFalse,
        reason: '按 N/P、托盘切歌或自动下一首换歌后不得替换错曲目',
      );
      expect(
        samePlaybackContext(
          now: song,
          nowIndex: 3,
          startedGlobalId: '0:x',
          startedIndex: 2,
        ),
        isFalse,
      );
      expect(
        samePlaybackContext(
          now: null,
          nowIndex: -1,
          startedGlobalId: '0:x',
          startedIndex: 2,
        ),
        isFalse,
      );
    });
  });

  group('freshApiError：lastError 快照（L-1）', () {
    test('请求后新产生的错误才采用', () {
      expect(freshApiError(null, '登录态失效'), '登录态失效');
      expect(freshApiError('旧错误', '新错误'), '新错误');
    });

    test('前后一致（陈旧扫码错误）或都为空 → 不采用', () {
      expect(freshApiError('上次扫码失败', '上次扫码失败'), isNull);
      expect(freshApiError(null, null), isNull);
      expect(freshApiError('旧错误', null), isNull);
    });
  });
}
