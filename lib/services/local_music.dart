import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import '../models/song.dart';
import '../core/constants.dart';

/// 本地音乐扫描服务
class LocalMusicService {
  static const List<String> _exts = [
    'mp3',
    'flac',
    'wav',
    'm4a',
    'aac',
    'ogg',
  ];

  Directory? _coverDirCache;

  /// 获取默认扫描目录（音乐目录 + 下载目录）
  Future<List<String>> defaultScanPaths() async {
    final paths = <String>{};
    try {
      final dirs = await getExternalStorageDirectories();
      if (dirs != null) {
        for (final d in dirs) {
          paths.add(d.path);
        }
      }
    } catch (_) {}
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) paths.add(downloads.path);
    } catch (_) {}
    try {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
      if (home.isNotEmpty) {
        final music = Directory(p.join(home, 'Music'));
        if (music.existsSync()) paths.add(music.path);
      }
    } catch (_) {}
    if (paths.isEmpty) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        paths.add(appDir.path);
      } catch (_) {}
    }
    return paths.toList();
  }

  /// 扫描目录（递归，限制层级防卡顿）
  Future<List<Song>> scanDirectory(String dirPath,
      {void Function(int found)? onProgress}) async {
    final songs = <Song>[];
    final root = Directory(dirPath);
    if (!root.existsSync()) return songs;

    final queue = <Directory>[root];
    const maxDirs = 2000;
    var visited = 0;

    while (queue.isNotEmpty && visited < maxDirs) {
      final dir = queue.removeAt(0);
      visited++;
      try {
        final children = dir.listSync(followLinks: false);
        for (final f in children) {
          try {
            if (f is Directory) {
              queue.add(f);
            } else if (f is File) {
              final ext =
                  p.extension(f.path).toLowerCase().replaceFirst('.', '');
              if (_exts.contains(ext)) {
                songs.add(await songFromFile(f));
                onProgress?.call(songs.length);
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    return songs;
  }

  /// 单个音频文件 -> Song（读取标题/歌手/专辑/时长与内嵌封面）
  Future<Song> songFromFile(File file) async {
    var title = p.basenameWithoutExtension(file.path);
    var artist = '未知歌手';
    var album = '';
    var duration = 0;
    var cover = '';
    try {
      final meta = readMetadata(file);
      if (meta.title != null && meta.title!.isNotEmpty) {
        title = meta.title!;
      }
      final metaArtist = meta.artist ?? meta.albumArtist;
      if (metaArtist != null && metaArtist.isNotEmpty) {
        artist = metaArtist;
      }
      album = meta.album ?? '';
      duration = (meta.duration?.inSeconds) ?? 0;
      cover = await _extractCover(meta);
    } catch (_) {}
    // 没有可用标签时，从「歌手 - 歌名」这种文件名里回退解析
    if (title == p.basenameWithoutExtension(file.path)) {
      final sep = title.indexOf(' - ');
      if (sep > 0) {
        final nameFromFile = title.substring(sep + 3).trim();
        artist = title.substring(0, sep).trim();
        if (nameFromFile.isNotEmpty) title = nameFromFile;
      }
    }
    return Song(
      id: 'local_${file.path.hashCode.toRadixString(16)}',
      platform: JXPlatform.local,
      title: title,
      artist: artist,
      album: album,
      coverUrl: cover,
      audioUrl: file.path,
      duration: duration,
    );
  }

  /// 缓存目录（临时目录下的 jxmusic_covers）
  Future<Directory?> _coverDir() async {
    if (_coverDirCache != null) return _coverDirCache;
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'jxmusic_covers'));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      _coverDirCache = dir;
      return dir;
    } catch (e) {
      debugPrint('[JXMusic] 创建封面缓存目录失败: $e');
      return null;
    }
  }

  /// 把音频文件内嵌的封面（ID3 APIC / FLAC PICTURE 等）落到本地缓存文件，
  /// 返回文件路径供 UI 显示；同专辑共用同一张缓存图，没有封面返回空串。
  Future<String> _extractCover(AudioMetadata meta) async {
    final pictures = meta.pictures;
    if (pictures.isEmpty) return '';
    final bytes = pictures.first.bytes;
    if (bytes.isEmpty) return '';
    try {
      final dir = await _coverDir();
      if (dir == null) return '';
      final isPng = pictures.first.mimetype.contains('png');
      final key = '${meta.albumArtist ?? meta.artist ?? ''}|${meta.album ?? ''}';
      final digest = md5
          .convert(utf8.encode(key.isEmpty ? meta.file.path : key))
          .toString();
      final file = File(p.join(dir.path, '$digest.${isPng ? 'png' : 'jpg'}'));
      if (!file.existsSync()) {
        await file.writeAsBytes(bytes, flush: false);
      }
      return file.path;
    } catch (e) {
      debugPrint('[JXMusic] 提取本地封面失败: $e');
      return '';
    }
  }
}
