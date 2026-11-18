import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../models/song.dart';
import 'api/http.dart';
import 'local_music.dart';

/// 一条已下载记录
class DownloadedEntry {
  final Song song;
  final File file;
  final int bytes;
  final DateTime modifiedAt;

  const DownloadedEntry({
    required this.song,
    required this.file,
    required this.bytes,
    required this.modifiedAt,
  });
}

/// 下载服务：把歌曲保存到系统下载目录（Windows：下载/JXMusic；
/// Android：应用外部存储目录下的 JXMusic），并在保存过程中回报进度。
class DownloadService {
  DownloadService({this.directoryOverride, LocalMusicService? localMusic})
      : _localMusic = localMusic ?? LocalMusicService();

  static final DownloadService instance = DownloadService();

  /// 指定保存目录（测试用；为空时按平台取系统下载目录）
  final Directory? directoryOverride;

  final LocalMusicService _localMusic;

  static const List<String> _audioExtensions = [
    '.mp3',
    '.flac',
    '.wav',
    '.m4a',
    '.aac',
    '.ogg',
  ];

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
    if (name.length > 100) {
      var end = 100;
      // 截断点落在 UTF-16 代理对中间会留下孤立代理项，
      // 平台文件名编码（Windows/ohos）会直接抛 FileSystemException，退一位。
      final unit = name.codeUnitAt(end - 1);
      if (unit >= 0xD800 && unit <= 0xDBFF) end--;
      name = name.substring(0, end);
    }
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

  /// 正在下载的目标路径（防并发：同一首歌并发下载写同一个文件会交错损坏）。
  static final Set<String> _inFlightPaths = <String>{};

  /// 下载歌曲，返回最终保存路径。重复下载会自动加 (2)(3) 后缀。
  ///
  /// 先写 `<目标名>.part` 再原子重命名：进程中途被杀/断网不会留下顶着正式
  /// 扩展名的半截文件（那种文件会被 listDownloaded 当成可播条目、且永远
  /// 挡住去重循环导致同歌永远下成 "(2)"）。
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
    while (file.existsSync() || _inFlightPaths.contains(file.path)) {
      index++;
      file = File(p.join(dir.path, '$base ($index)$ext'));
    }
    final part = File('${file.path}.part');
    _inFlightPaths.add(file.path);
    try {
      if (part.existsSync()) {
        part.deleteSync();
      }
      await JXHttp.dio.download(
        url,
        part.path,
        options: Options(headers: headersFor(song.platform)),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call(received / total);
          }
        },
      );
      await part.rename(file.path);
    } catch (e) {
      // 下载中断：清掉半截 .part，不留垃圾
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      rethrow;
    } finally {
      _inFlightPaths.remove(file.path);
    }
    return file.path;
  }

  /// 列出下载目录里已下载的音频（读取内嵌封面/时长，按修改时间倒序）
  Future<List<DownloadedEntry>> listDownloaded() async {
    final dir = await targetDirectory();
    final entries = <DownloadedEntry>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!_audioExtensions.contains(ext)) continue;
      try {
        final stat = entity.statSync();
        final song = await _localMusic.songFromFile(entity);
        entries.add(DownloadedEntry(
          song: song,
          file: entity,
          bytes: stat.size,
          modifiedAt: stat.modified,
        ));
      } catch (_) {
        // 单个文件读失败不影响整个列表
      }
    }
    entries.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return entries;
  }

  /// 删除一个已下载文件
  Future<void> deleteDownload(DownloadedEntry entry) async {
    if (entry.file.existsSync()) {
      await entry.file.delete();
    }
  }
}
