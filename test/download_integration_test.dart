import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/download_service.dart';

/// 真实下载链路的集成检查（需要联网，默认跳过）：
///   flutter test test/download_integration_test.dart --run-skipped
///
/// 覆盖：解析酷狗免费歌曲直链 -> 带 Referer 下载 -> 文件名/大小/进度回调。
void main() {
  test('酷狗免费歌曲可完整下载落盘', () async {
    final api = KuGouApi();
    final results = await api.searchSongs('国际歌', size: 6);
    final free = results.where((s) => !s.vip).toList();
    expect(free, isNotEmpty, reason: '没有拿到免费歌曲，接口可能变动');

    final song = free.first;
    final url = await api.getPlayUrl(song);
    expect(url, isNotNull, reason: '免费歌曲应能解析出播放直链');

    final dir = await Directory.systemTemp.createTemp('jxmusic_dl_test_');
    try {
      final service = DownloadService(directoryOverride: dir);
      var lastProgress = 0.0;
      final path = await service.download(
        song.copyWith(audioUrl: url),
        onProgress: (v) => lastProgress = v,
      );
      final file = File(path);
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(50 * 1024));
      expect(file.path.endsWith('.mp3'), isTrue);
      expect(lastProgress, greaterThan(0.9));
    } finally {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)), skip: '需要联网的真实下载检查，按需手动执行');
}
