import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/download_service.dart';
import 'package:path/path.dart' as p;

/// 下载目录管理（列表/删除）的离线测试，用临时目录代替系统下载目录。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jxmusic_dl_list_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('listDownloaded：只列出音频，忽略图片与子目录，按修改时间倒序', () async {
    final olderPath = p.join(dir.path, '周杰伦 - 晴天.mp3');
    final newerPath = p.join(dir.path, '群星 - 国际歌.flac');
    File(olderPath)
      ..writeAsBytesSync(List.filled(2048, 0))
      ..setLastModifiedSync(DateTime(2026, 1, 1, 10));
    File(p.join(dir.path, '封面.jpg')).writeAsBytesSync(List.filled(64, 0));
    Directory(p.join(dir.path, 'sub')).createSync();
    File(p.join(dir.path, 'sub', 'nested.mp3'))
        .writeAsBytesSync(List.filled(1024, 0));
    File(newerPath)
      ..writeAsBytesSync(List.filled(4096, 0))
      ..setLastModifiedSync(DateTime(2026, 2, 2, 11));

    final service = DownloadService(directoryOverride: dir);
    final entries = await service.listDownloaded();

    expect(entries.length, 2);
    expect(entries.first.file.path, newerPath);
    expect(entries.first.bytes, 4096);
    // 没有可用标签时按「歌手 - 歌名」文件名回退解析
    expect(entries.first.song.title, '国际歌');
    expect(entries.first.song.artist, '群星');
    expect(entries.first.song.platform, JXPlatform.local);
    expect(entries.first.song.audioUrl, newerPath);
    expect(entries.last.song.title, '晴天');
    expect(entries.last.file.path, olderPath);
  });

  test('deleteDownload：删除本地文件', () async {
    final filePath = p.join(dir.path, 'A - B.mp3');
    final file = File(filePath)..writeAsBytesSync(List.filled(1024, 0));
    final service = DownloadService(directoryOverride: dir);
    final entries = await service.listDownloaded();
    expect(entries.length, 1);

    await service.deleteDownload(entries.first);
    expect(file.existsSync(), isFalse);
    expect(await service.listDownloaded(), isEmpty);
  });

  test('targetDirectory：覆盖目录不存在时自动创建', () async {
    final nested = Directory(p.join(dir.path, 'nested', 'downloads'));
    final service = DownloadService(directoryOverride: nested);
    final resolved = await service.targetDirectory();
    expect(resolved.path, nested.path);
    expect(nested.existsSync(), isTrue);
  });

  test('buildFileName：扩展名随播放链接变化', () {
    const song = Song(
      id: 'x',
      platform: JXPlatform.kugou,
      title: '晴天',
      artist: '周杰伦',
    );
    expect(
      DownloadService.buildFileName(song,
          url: 'https://x/y/song.flac?token=1'),
      '周杰伦 - 晴天.flac',
    );
    expect(
      DownloadService.buildFileName(song, url: 'https://x/y/stream'),
      '周杰伦 - 晴天.mp3',
    );
  });
}
