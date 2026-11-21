import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/player_service.dart';

/// 队列死链自动跳过回归（真机实测发现）：
///
/// 网易云 VIP/试听曲目经常解析不出直链（`无可播放链接`）。修复前：
/// 自动下一首 / 播放器报错重试撞上死链曲目时整个队列停死在 00:00，
/// 且不给任何用户提示（不写 lastResolutionError，SnackBar 链路不触发）。
///
/// 修复后：
/// - 自动前进（自然播完、报错重试、用户按下一首）：提示「已跳过」后跳
///   队列下一首，队列不中断；
/// - 跳到队尾（无下一首可跳）：停下并给出可行动的提示文案；
/// - 死链曲目从此不再静默：所有路径都写 lastResolutionError。
void main() {
  Song online(String id, String title, {String? audioUrl}) => Song(
        id: id,
        platform: JXPlatform.netease,
        title: title,
        artist: '测试歌手',
        audioUrl: audioUrl,
      );

  test('用户主动点播死链曲目：停下并给出提示（不再静默）', () async {
    final service = PlayerService(
      initPlayer: false,
      urlResolver: (_) async => null,
    );
    final dead = online('ne_dead', '死链歌');

    await service.playSong(dead);

    expect(service.lastResolutionError, contains('死链歌'));
    expect(service.lastResolutionError, contains('暂无播放链接'));
  });

  test('自动前进撞死链曲目：提示已跳过并继续播下一首，队列不停死', () async {
    final started = <Song>[];
    final service = PlayerService(
      initPlayer: false,
      onSongStarted: started.add,
      urlResolver: (song) async =>
          song.title == '死链歌' ? null : 'https://cdn.example.com/${song.id}.mp3',
    );
    final a = online('ne_a', '正常歌A', audioUrl: 'https://cdn.example.com/a.mp3');
    final dead = online('ne_dead', '死链歌');
    final c = online('ne_c', '正常歌C');

    await service.playSong(a, queue: [a, dead, c]);
    // initPlayer:false：open 是 no-op，但 onSongStarted 仍回调（既有契约）
    expect(started.map((s) => s.title), ['正常歌A']);

    await service.next();

    // 死链歌被跳过，当前曲目是 C 而不是停在死链歌上
    expect(service.currentSong!.title, '正常歌C');
    expect(started.map((s) => s.title), ['正常歌A', '正常歌C']);
    expect(service.currentIndex, 2);
    // 队列项 C 的直链已解析回写
    expect(service.queue[2].audioUrl, 'https://cdn.example.com/ne_c.mp3');
    // 给了「已跳过」提示
    expect(service.lastResolutionError, contains('已跳过'));
  });

  test('死链曲目已是队尾：停下并提示（无死循环、不越界）', () async {
    final service = PlayerService(
      initPlayer: false,
      urlResolver: (song) async =>
          song.title == '死链歌' ? null : 'https://cdn.example.com/x.mp3',
    );
    final a = online('ne_a', '正常歌A', audioUrl: 'https://cdn.example.com/a.mp3');
    final dead = online('ne_dead', '死链歌');

    await service.playSong(a, queue: [a, dead]);
    await service.next();

    // 停在队尾死链歌上，不再前进，也没有「已跳过」的误导提示
    expect(service.currentIndex, 1);
    expect(service.lastResolutionError, isNotNull);
    expect(service.lastResolutionError, contains('暂无播放链接'));
    expect(service.lastResolutionError!.contains('已跳过'), isFalse);
  });

  test('连续多首死链：逐首提示跳过，直到第一首可播曲目', () async {
    final service = PlayerService(
      initPlayer: false,
      urlResolver: (song) async =>
          song.title.startsWith('死链') ? null : 'https://cdn.example.com/${song.id}.mp3',
    );
    final a = online('ne_a', '正常歌A', audioUrl: 'https://cdn.example.com/a.mp3');
    final d1 = online('ne_d1', '死链1');
    final d2 = online('ne_d2', '死链2');
    final d3 = online('ne_d3', '死链3');
    final e = online('ne_e', '正常歌E');

    await service.playSong(a, queue: [a, d1, d2, d3, e]);
    await service.next();

    expect(service.currentSong!.title, '正常歌E');
    expect(service.currentIndex, 4);
    expect(service.lastResolutionError, contains('已跳过'));
  });

  test('START_FILE 的 completed=false 不触发切歌（+43 级联跳歌根因回归）', () async {
    // 真机取证（hilog）：media_kit 在 mpv START_FILE（开始加载新文件）时
    // 会向 completed 流发 false。修复前订阅回调不看值直接 _onTrackComplete，
    // 导致每次 open 新歌立刻被切到下一首：级联中止所有进行中的加载
    // （产生大量「Failed to open」假错误）、一路跳到队尾才停——网易云
    // 歌单「点了没反应」/ QQ 歌单「大量跳过」的真根因。
    final started = <Song>[];
    final service = PlayerService(
      initPlayer: false,
      onSongStarted: started.add,
      urlResolver: (song) async => 'https://cdn.example.com/${song.id}.mp3',
    );
    final a = online('ne_a', '正常歌A', audioUrl: 'https://cdn.example.com/a.mp3');
    final b = online('ne_b', '正常歌B', audioUrl: 'https://cdn.example.com/b.mp3');

    await service.playSong(a, queue: [a, b]);

    // 开始加载 A（START_FILE）→ completed=false：不能切歌
    service.onCompletedEvent(false);
    await pumpEventQueue();
    expect(service.currentSong!.title, '正常歌A');
    expect(started.map((s) => s.title), ['正常歌A']);

    // 真正播完（eof-reached）→ completed=true：切到下一首
    service.onCompletedEvent(true);
    await pumpEventQueue();
    expect(service.currentSong!.title, '正常歌B');
    expect(started.map((s) => s.title), ['正常歌A', '正常歌B']);
  });
}
