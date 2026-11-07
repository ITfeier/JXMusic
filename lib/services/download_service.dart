import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../models/song.dart';
import 'api/http.dart';

/// 下载服务：把歌曲保存到系统下载目录（Windows：下载/JXMusic；
/// Android：应用外部存储目录下的 JXMusic），并在保存过程中回报进度。
class DownloadService {
  DownloadService({this.directoryOverride});

  static final DownloadService instance = DownloadService();

  /// 指定保存目录（测试用；为空时按平台取系统下载目录）
  final Directory? directoryOverride;

  /// 各平台 CDN 需要对应 Referer 才允许下载
  static Map<String, String> headersFor(int platform) {
    switch (platform) {
      case JXPlatform.qq:
        return const {'Referer': 'https://y.qq.com/'};
      case JXPlatform.netease:
        return const {'Referer': 'https://music.163.com/'};
      case JXPlatform.kugou:
        return const {'Referer': 'https://m.kugou.com/'};
      default:
        return const {};
    }
  }

  /// 生成安全的文件名（过滤 Windows/Android 非法字符），扩展名优先取播放链接后缀
  static String buildFileName(Song song, {String url = ''}) {
    final raw = '${song.artist} - ${song.title}'.trim();
    var name = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'[\x00-\x1F]'), '')
        .trim();
    // 标题/歌手都为空时 raw 只剩 " - "，去掉分隔符后为空则兜底文件名
    if (name.replaceAll(RegExp(r'[-_\s]+'), '').isEmpty) name = '未命名';
    if (name.length > 100) name = name.substring(0, 100);
    return '$name${_extensionOf(url)}';
  }

  static String _extensionOf(String url) {
    if (url.isEmpty) return '.mp3';
    try {
      final ext = p.extension(Uri.parse(url).path).toLowerCase();
      if (ext.length > 1 && ext.length <= 6) return ext;
    } catch (_) {}
    return '.mp3';
  }

  /// 下载目录（自动创建）
  Future<Directory> targetDirectory() async {
    final override = directoryOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {}
    if (base == null) {
      try {
        base = await getExternalStorageDirectory();
      } catch (_) {}
    }
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'JXMusic'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 下载歌曲，返回最终保存路径。重复下载会自动加 (2)(3) 后缀。
  Future<String> download(
    Song song, {
    void Function(double progress)? onProgress,
  }) async {
    final url = song.audioUrl;
    if (url == null || url.isEmpty) {
      throw StateError('歌曲没有可下载的播放链接');
    }
    final dir = await targetDirectory();
    final fileName = buildFileName(song, url: url);
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var file = File(p.join(dir.path, fileName));
    var index = 1;
    while (file.existsSync()) {
      index++;
      file = File(p.join(dir.path, '$base ($index)$ext'));
    }
    await JXHttp.dio.download(
      url,
      file.path,
      options: Options(headers: headersFor(song.platform)),
      onReceiveProgress: (received, total) {
        if (total > 0) {
          onProgress?.call(received / total);
        }
      },
    );
    return file.path;
  }
}
