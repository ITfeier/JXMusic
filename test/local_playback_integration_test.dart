import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/player_service.dart';

/// 本地音乐加密格式与播放链路挂接的集成回归（T0）。
///
/// 对应架构评审：
/// - R-1：resolver 结果只用于打开播放器，不得写回队列 / 播放历史（历史必须保留
///   源文件路径，否则解密缓存被清理后无法回放）；
/// - R-11：队列懒解密失败要给出具体中文原因（lastResolutionError），不得静默。
void main() {
  Song localSong(String path) => Song(
    id: 'local_${path.hashCode.toRadixString(16)}',
    platform: JXPlatform.local,
    title: '加密歌',
    artist: '测试歌手',
    audioUrl: path,
  );

  test('本地加密曲目：即使 audioUrl 非空也走 resolver，且队列/历史保留源路径（R-1）', () async {
    final resolvedSources = <String?>[];
    final started = <Song>[];
    final service = PlayerService(
      initPlayer: false,
      onSongStarted: started.add,
      urlResolver: (song) async {
        resolvedSources.add(song.audioUrl);
        return '/app/cache/decrypted/data.flac';
      },
    );

    const sourcePath = '/sdcard/QQMusic/a.qmcflac';
    final song = localSong(sourcePath);
    await service.playSong(song, queue: <Song>[song]);

    // 1) 本地曲目必须经过 resolver（把密文路径换成解密缓存路径）
    expect(resolvedSources, <String?>[sourcePath]);
    // 2) 队列项保留源路径（不是缓存路径）
    expect(service.queue.single.audioUrl, sourcePath);
    // 3) 播放历史回调拿到的也是源路径
    expect(started.single.audioUrl, sourcePath);
  });

  test(
    '本地解密失败：lastResolutionError 使用 LocalFormatService 的中文原因（R-11）',
    () async {
      final service = PlayerService(
        initPlayer: false,
        urlResolver: (_) async => null,
        resolutionErrorHint: () => 'QQ 音乐该文件尾部不含密钥（musicex/STag），暂不支持离线解密',
      );

      await service.playSong(localSong('/sdcard/QQMusic/b.mflac'));

      expect(service.lastResolutionError, contains('尾部不含密钥'));
      service.clearResolutionError();
      expect(service.lastResolutionError, isNull);
    },
  );

  test('本地解密失败且无 hint 时回退通用中文文案（R-11）', () async {
    final service = PlayerService(
      initPlayer: false,
      urlResolver: (_) async => null,
    );

    await service.playSong(localSong('/sdcard/QQMusic/c.kgm'));

    expect(service.lastResolutionError, contains('本地文件无法解密播放'));
  });

  test('普通格式本地曲目：resolver 原样返回源路径，队列不被改写', () async {
    const path = '/sdcard/Music/a.mp3';
    final service = PlayerService(
      initPlayer: false,
      urlResolver: (song) async => song.audioUrl,
    );

    await service.playSong(localSong(path));

    expect(service.queue.single.audioUrl, path);
  });

  test('在线歌曲行为不变：audioUrl 为空时解析并回写队列', () async {
    final service = PlayerService(
      initPlayer: false,
      urlResolver: (_) async => 'https://cdn.example.com/a.mp3',
    );
    const song = Song(
      id: 'qq_1',
      platform: JXPlatform.qq,
      title: '在线歌',
      artist: '歌手',
    );

    await service.playSong(song);

    expect(service.queue.single.audioUrl, 'https://cdn.example.com/a.mp3');
  });

  test('在线歌曲：audioUrl 非空时不重复解析（保持既有行为）', () async {
    var resolveCalls = 0;
    final service = PlayerService(
      initPlayer: false,
      urlResolver: (_) async {
        resolveCalls += 1;
        return 'https://cdn.example.com/b.mp3';
      },
    );
    const song = Song(
      id: 'qq_2',
      platform: JXPlatform.qq,
      title: '在线歌2',
      artist: '歌手',
      audioUrl: 'https://cdn.example.com/c.mp3',
    );

    await service.playSong(song);

    expect(resolveCalls, 0);
    expect(service.queue.single.audioUrl, 'https://cdn.example.com/c.mp3');
  });
}
