import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/models/lyric.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/player_service.dart';

/// R1.3 歌词状态机回归测试：
/// - 初始 idle；切歌 loading → ready / empty / error；
/// - 切歌即加载，不依赖 `_player.open` 成功；
/// - retryLyrics() 可重试，加载中 no-op；
/// - 同一首歌重复 playSong 不重复请求；
/// - 切歌后旧响应丢弃；
/// - dispose 后异步返回不 notify（不触发 debug 断言）；
/// - setLyrics 兼容（同步置 ready/empty）。
Song _song(String id,
        {int platform = 0, String title = '测试歌', String? audioUrl}) =>
    Song(
      id: id,
      platform: platform,
      title: title,
      artist: '测试歌手',
      audioUrl: audioUrl,
    );

/// 等待异步回调落到微任务/事件队列
Future<void> _drain() => Future<void>.delayed(Duration.zero);

void main() {
  group('初始状态', () {
    test('新建 PlayerService 且无曲目时 lyricsStatus == idle', () {
      final service = PlayerService(initPlayer: false);
      addTearDown(service.dispose);

      expect(service.lyricsStatus, LyricsStatus.idle);
      expect(service.lyrics, isEmpty);
    });

    test('clearQueue 后回到 idle', () async {
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (_) async => const [LyricLine(0, 'x')],
      );
      addTearDown(service.dispose);

      await service.playSong(_song('a'));
      await _drain();
      expect(service.lyricsStatus, LyricsStatus.ready);

      service.clearQueue();
      expect(service.lyricsStatus, LyricsStatus.idle);
      expect(service.lyrics, isEmpty);
    });
  });

  group('切歌 → loading → ready/empty/error（不依赖 open 成功）', () {
    test('切歌瞬间 loading；resolver 完成后 ready 且有歌词', () async {
      final completer = Completer<List<LyricLine>>();
      var calls = 0;
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (_) {
          calls++;
          return completer.future;
        },
      );
      addTearDown(service.dispose);

      // 无 audioUrl 且无 urlResolver：直链解析失败，歌词仍必须加载
      await service.playSong(_song('a'));
      expect(service.lyricsStatus, LyricsStatus.loading,
          reason: '切歌即 loading，不等播放器 open 成功');
      expect(calls, 1);
      expect(service.lyrics, isEmpty);

      completer.complete(const [LyricLine(1000, '第一句')]);
      await _drain();

      expect(service.lyricsStatus, LyricsStatus.ready);
      expect(service.lyrics, hasLength(1));
      expect(service.lyrics.first.text, '第一句');
    });

    test('resolver 返回空列表 → empty', () async {
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (_) async => const <LyricLine>[],
      );
      addTearDown(service.dispose);

      await service.playSong(_song('a'));
      await _drain();

      expect(service.lyricsStatus, LyricsStatus.empty);
      expect(service.lyrics, isEmpty);
    });

    test('resolver 抛错 → error（UI 展示重试按钮）', () async {
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (_) async => throw StateError('网络异常'),
      );
      addTearDown(service.dispose);

      await service.playSong(_song('a'));
      await _drain();

      expect(service.lyricsStatus, LyricsStatus.error);
      expect(service.lyrics, isEmpty);
    });

    test('未注入 resolver 时不发请求，保持 idle', () async {
      final service = PlayerService(initPlayer: false);
      addTearDown(service.dispose);

      await service.playSong(_song('a'));
      expect(service.lyricsStatus, LyricsStatus.idle);
    });
  });

  group('retryLyrics', () {
    test('失败后 retryLyrics 强制重新请求并置 ready', () async {
      var calls = 0;
      var fail = true;
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (_) async {
          calls++;
          if (fail) throw StateError('第一次失败');
          return const [LyricLine(0, '重试成功')];
        },
      );
      addTearDown(service.dispose);

      await service.playSong(_song('a'));
      await _drain();
      expect(service.lyricsStatus, LyricsStatus.error);
      expect(calls, 1);

      fail = false;
      service.retryLyrics();
      expect(calls, 2, reason: '重试必须重新请求（不受同曲去重限制）');
      await _drain();

      expect(service.lyricsStatus, LyricsStatus.ready);
      expect(service.lyrics.first.text, '重试成功');
    });

    test('loading 中 retryLyrics 安全 no-op（不重复请求、不抛）', () async {
      final completer = Completer<List<LyricLine>>();
      var calls = 0;
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (_) {
          calls++;
          return completer.future;
        },
      );
      addTearDown(service.dispose);

      await service.playSong(_song('a'));
      expect(() => service.retryLyrics(), returnsNormally);
      expect(calls, 1);
      expect(service.lyricsStatus, LyricsStatus.loading);

      completer.complete(const [LyricLine(0, 'x')]);
      await _drain();
      expect(service.lyricsStatus, LyricsStatus.ready);
    });

    test('无当前曲目时 retryLyrics 安全 no-op', () {
      final service = PlayerService(initPlayer: false);
      addTearDown(service.dispose);

      expect(() => service.retryLyrics(), returnsNormally);
      expect(service.lyricsStatus, LyricsStatus.idle);
    });
  });

  group('去重与过期响应', () {
    test('同一首歌重复 playSong 不重复请求歌词', () async {
      var calls = 0;
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (_) async {
          calls++;
          return const [LyricLine(0, 'x')];
        },
      );
      addTearDown(service.dispose);

      final a = _song('same');
      await service.playSong(a);
      await _drain();
      await service.playSong(a);
      await _drain();

      expect(calls, 1, reason: '同曲（globalId 相同）不重复请求');
      expect(service.lyricsStatus, LyricsStatus.ready);
    });

    test('切歌后旧曲目响应到达必须丢弃', () async {
      final slow = Completer<List<LyricLine>>();
      final fast = Completer<List<LyricLine>>();
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (song) => song.id == 'a' ? slow.future : fast.future,
      );
      addTearDown(service.dispose);

      await service.playSong(_song('a'));
      await service.playSong(_song('b'));

      fast.complete(const [LyricLine(0, 'B 的歌词')]);
      await _drain();
      expect(service.lyrics.first.text, 'B 的歌词');

      // A 的慢响应现在才到：不得覆盖 B
      slow.complete(const [LyricLine(0, 'A 的旧歌词')]);
      await _drain();
      expect(service.lyrics.first.text, 'B 的歌词',
          reason: '过期响应必须被丢弃（globalId/请求序号守卫）');
      expect(service.lyricsStatus, LyricsStatus.ready);
    });
  });

  group('dispose 安全与兼容', () {
    test('dispose 后歌词响应到达不 notify（不触发 debug 断言）', () async {
      final completer = Completer<List<LyricLine>>();
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (_) => completer.future,
      );

      await service.playSong(_song('a'));
      expect(service.lyricsStatus, LyricsStatus.loading);
      service.dispose();

      completer.complete(const [LyricLine(0, '迟到')]);
      await _drain();
      // 没有断言/异常即说明 dispose 后没有 notifyListeners
    });

    test('setLyrics 兼容：非空 → ready，空 → empty', () {
      final service = PlayerService(initPlayer: false);
      addTearDown(service.dispose);

      service.setLyrics(const [LyricLine(0, 'a')]);
      expect(service.lyricsStatus, LyricsStatus.ready);
      expect(service.lyrics, hasLength(1));

      service.setLyrics(const []);
      expect(service.lyricsStatus, LyricsStatus.empty);
      expect(service.lyrics, isEmpty);
    });

    test('setLyrics 会作废在途请求（不被迟到响应覆盖）', () async {
      final completer = Completer<List<LyricLine>>();
      final service = PlayerService(
        initPlayer: false,
        lyricsResolver: (_) => completer.future,
      );
      addTearDown(service.dispose);

      await service.playSong(_song('a'));
      service.setLyrics(const [LyricLine(0, '手动注入')]);
      expect(service.lyricsStatus, LyricsStatus.ready);

      completer.complete(const [LyricLine(0, '网络迟到')]);
      await _drain();
      expect(service.lyrics.first.text, '手动注入');
    });
  });
}
