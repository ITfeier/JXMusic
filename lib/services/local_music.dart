import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../models/song.dart';
import 'local_format_service.dart';
import 'local_formats/supported_formats.dart';
import 'local_paths.dart';

/// 单个扫描路径的错误（目录不存在/无权限等），不中断其它目录的扫描。
class ScanPathError {
  const ScanPathError({required this.path, required this.message});

  final String path;
  final String message;

  @override
  String toString() => '$path：$message';
}

/// 多目录扫描结果：成功识别的歌曲 + 有问题的路径列表。
class ScanResult {
  const ScanResult({
    this.songs = const <Song>[],
    this.errors = const <ScanPathError>[],
  });

  final List<Song> songs;
  final List<ScanPathError> errors;

  bool get isEmpty => songs.isEmpty;
  int get errorCount => errors.length;
}

/// 「歌手 - 歌名」文件名回退合并（PRD REQ-4 / AC-6：标签读不到才回退）。
///
/// 只填补**缺失**字段，不覆盖已读到的标签：
/// - [hasTagTitle] 为 true 时保留标签 [title]，否则用文件名里的「歌名」；
/// - [hasTagArtist] 为 true 时保留标签 [artist]，否则用文件名里的「歌手」；
/// - 文件名不含「 - 」或解析结果为空时原样返回。
///
/// 抽成纯函数便于单测：标题回退逻辑曾无条件用文件名覆盖标签（评审 R-18）。
({String title, String artist}) mergeFileNameFallback({
  required String baseName,
  required String title,
  required String artist,
  required bool hasTagTitle,
  required bool hasTagArtist,
}) {
  if (hasTagTitle && hasTagArtist) return (title: title, artist: artist);
  final sep = baseName.indexOf(' - ');
  if (sep <= 0) return (title: title, artist: artist);
  final nameFromFile = baseName.substring(sep + 3).trim();
  final artistFromFile = baseName.substring(0, sep).trim();
  if (nameFromFile.isEmpty || artistFromFile.isEmpty) {
    return (title: title, artist: artist);
  }
  return (
    title: hasTagTitle ? title : nameFromFile,
    artist: hasTagArtist ? artist : artistFromFile,
  );
}

/// 本地音乐扫描服务。
///
/// - [scanDirectories]：多目录合并扫描（BFS、全局最多 2000 个目录、跳过隐藏目录
///   与 `Android/data`、`Android/obb`、按绝对路径去重），单目录/单文件异常只记录
///   不中断（ADR-004 v1.0 D5 / 评审 R-6）；
/// - [songFromFile]：单个音频文件 -> [Song]；加密格式用 [LocalFormatService]
///   判断扩展名，NCM 扫描时直接读标签/封面，QMC/KGM 回退文件名；
/// - [enrichFromDecrypted]：QMC/KGM 首次解密成功后从解密产物回填标签（R-17）。
class LocalMusicService {
  LocalMusicService({this.formats, LocalPathsStore? pathsStore})
    : pathsStore = pathsStore ?? LocalPathsStore();

  /// 单次扫描最多遍历的目录数（全局合计，PRD 非功能需求：避免大目录卡顿）。
  static const int maxScanDirectories = 2000;

  /// 每发现多少个文件回调一次进度（进度语义是「已发现数」）。
  static const int progressStep = 20;

  /// 解密编排服务（可能为 null：仅扫描、不解密，兼容旧调用）。
  final LocalFormatService? formats;

  /// 扫描目录配置。
  final LocalPathsStore pathsStore;

  Directory? _coverDirCache;

  /// 获取默认扫描目录（音乐目录 + 下载目录 + 平台常用目录）。
  ///
  /// 保留旧接口签名（既有调用方兼容）；逻辑委托 [LocalPathsStore.defaultCandidates]。
  Future<List<String>> defaultScanPaths() => pathsStore.defaultCandidates();

  /// 扫描多个目录并合并去重。
  ///
  /// [onProgress] 传入当前已发现歌曲数（每 [progressStep] 个文件回调一次，
  /// 扫描结束时再回调一次最终值），供 UI 显示扫描进度。
  Future<ScanResult> scanDirectories(
    List<String> paths, {
    void Function(int found)? onProgress,
  }) async {
    final songs = <Song>[];
    final errors = <ScanPathError>[];
    final seenDirs = <String>{};
    final seenFiles = <String>{};
    final queue = <Directory>[];

    // 根目录先做存在性/可扫描性校验：单个目录有问题只记录错误，不影响其它目录。
    for (final raw in paths) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      if (_isSystemDataPath(path)) {
        errors.add(
          ScanPathError(
            path: path,
            message: '系统数据目录（Android/data、Android/obb）不支持扫描',
          ),
        );
        continue;
      }
      if (!seenDirs.add(_pathKey(path))) continue;
      final dir = Directory(path);
      bool exists;
      try {
        exists = await dir.exists();
      } catch (_) {
        exists = false;
      }
      if (!exists) {
        errors.add(ScanPathError(path: path, message: '目录不存在或无法访问'));
        continue;
      }
      queue.add(dir);
    }

    var visited = 0;
    while (queue.isNotEmpty && visited < maxScanDirectories) {
      final dir = queue.removeAt(0);
      visited++;

      List<FileSystemEntity> children;
      try {
        children = dir.listSync(followLinks: false);
      } catch (e) {
        errors.add(
          ScanPathError(path: dir.path, message: '无法访问目录：${_errorText(e)}'),
        );
        continue;
      }

      // 目录/文件分别排序，保证多目录扫描结果顺序稳定、可复现。
      final childDirs = <Directory>[];
      final childFiles = <File>[];
      for (final entity in children) {
        try {
          if (entity is Directory) {
            if (!_isHiddenPath(entity.path) &&
                !_isSystemDataPath(entity.path)) {
              childDirs.add(entity);
            }
          } else if (entity is File) {
            if (!_isHiddenPath(entity.path)) childFiles.add(entity);
          }
        } catch (_) {}
      }
      childDirs.sort((a, b) => a.path.compareTo(b.path));
      childFiles.sort((a, b) => a.path.compareTo(b.path));

      for (final file in childFiles) {
        final ext = _extensionOf(file.path);
        if (ext.isEmpty || !LocalAudioFormats.allExtensions.contains(ext)) {
          continue;
        }
        if (!seenFiles.add(_pathKey(file.path))) continue;
        try {
          songs.add(await songFromFile(file, formats: formats));
          if (songs.length % progressStep == 0) {
            onProgress?.call(songs.length);
          }
        } catch (_) {
          // 单文件解析失败：跳过该文件（错误按目录隔离，不污染其它目录）
        }
      }

      for (final child in childDirs) {
        if (visited + queue.length >= maxScanDirectories) break;
        if (seenDirs.add(_pathKey(child.path))) queue.add(child);
      }

      // 目录枚举与下一目录之间让出事件循环，避免大目录卡 UI。
      await Future<void>.delayed(Duration.zero);
    }

    if (songs.isNotEmpty && songs.length % progressStep != 0) {
      onProgress?.call(songs.length);
    }
    return ScanResult(songs: songs, errors: errors);
  }

  /// 兼容旧接口：扫描单个目录，返回歌曲列表（丢弃错误明细）。
  Future<List<Song>> scanDirectory(
    String dirPath, {
    void Function(int found)? onProgress,
  }) async {
    final result = await scanDirectories(<String>[
      dirPath,
    ], onProgress: onProgress);
    return result.songs;
  }

  /// 单个音频文件 -> Song。
  ///
  /// 普通格式读取内嵌标签/封面；加密格式（NCM/QMC/KGM…）：
  /// - `audioUrl` 保留源文件路径（由播放器 resolver 解密，ADR-004 D4）；
  /// - NCM 扫描时用 [LocalFormatService.readTags] 直接读标题/歌手/专辑/封面；
  /// - QMC/KGM 保持文件名回退，首次播放解密成功后再回填（[enrichFromDecrypted]）。
  Future<Song> songFromFile(File file, {LocalFormatService? formats}) async {
    final service = formats ?? this.formats;
    final ext = _extensionOf(file.path);
    if (LocalAudioFormats.isEncrypted(ext)) {
      return _encryptedSongFromFile(file, ext, service);
    }
    return _commonSongFromFile(file);
  }

  Future<Song> _commonSongFromFile(File file) async {
    var title = p.basenameWithoutExtension(file.path);
    var artist = '未知歌手';
    var album = '';
    var duration = 0;
    var cover = '';
    var hasTagTitle = false;
    var hasTagArtist = false;
    try {
      final meta = readMetadata(file);
      final metaTitle = meta.title?.trim();
      if (metaTitle != null && metaTitle.isNotEmpty) {
        title = metaTitle;
        hasTagTitle = true;
      }
      final metaArtist = (meta.artist ?? meta.albumArtist)?.trim();
      if (metaArtist != null && metaArtist.isNotEmpty) {
        artist = metaArtist;
        hasTagArtist = true;
      }
      album = meta.album ?? '';
      duration = (meta.duration?.inSeconds) ?? 0;
      cover = await _extractCover(meta);
    } catch (_) {}
    // 只回退标签缺失的字段（评审 R-18）：标签 title 存在时不能用文件名覆盖。
    final merged = mergeFileNameFallback(
      baseName: p.basenameWithoutExtension(file.path),
      title: title,
      artist: artist,
      hasTagTitle: hasTagTitle,
      hasTagArtist: hasTagArtist,
    );
    return Song(
      id: _songId(file.path),
      platform: JXPlatform.local,
      title: merged.title,
      artist: merged.artist,
      album: album,
      coverUrl: cover,
      audioUrl: file.path,
      duration: duration,
    );
  }

  Future<Song> _encryptedSongFromFile(
    File file,
    String ext,
    LocalFormatService? formats,
  ) async {
    var title = p.basenameWithoutExtension(file.path);
    var artist = '未知歌手';
    var album = '';
    var cover = '';
    var hasTagTitle = false;
    var hasTagArtist = false;

    // 网易云 NCM 文件头内嵌完整标签与封面，扫描时即可展示（AC-6）。
    if (ext == 'ncm' && formats != null) {
      try {
        final tags = await formats.readTags(file.path);
        if (tags != null) {
          final tagTitle = tags.title?.trim();
          if (tagTitle != null && tagTitle.isNotEmpty) {
            title = tagTitle;
            hasTagTitle = true;
          }
          final tagArtist = tags.artist?.trim();
          if (tagArtist != null && tagArtist.isNotEmpty) {
            artist = tagArtist;
            hasTagArtist = true;
          }
          final tagAlbum = tags.album?.trim();
          if (tagAlbum != null && tagAlbum.isNotEmpty) album = tagAlbum;
          final coverBytes = tags.coverBytes;
          if (coverBytes != null && coverBytes.isNotEmpty) {
            cover = await formats.saveCoverBytes(coverBytes) ?? '';
          }
        }
      } catch (e) {
        debugPrint('[JXMusic] 读取 $ext 标签失败: $e');
      }
    }

    // QMC/KGM 等没有扫描期标签：回退文件名；NCM 只在标签缺失时回退（R-18）。
    final merged = mergeFileNameFallback(
      baseName: p.basenameWithoutExtension(file.path),
      title: title,
      artist: artist,
      hasTagTitle: hasTagTitle,
      hasTagArtist: hasTagArtist,
    );
    return Song(
      id: _songId(file.path),
      platform: JXPlatform.local,
      title: merged.title,
      artist: merged.artist,
      album: album,
      coverUrl: cover,
      // 保留源文件路径：历史/收藏可回放，播放时由 resolver 解密（ADR-004 D4）。
      audioUrl: file.path,
      duration: 0,
    );
  }

  /// 加密歌曲解密成功后回填元数据（评审 R-17）：从解密产物读取标题/歌手/
  /// 专辑/时长/封面；`audioUrl` 仍保留源文件路径。读不到返回原 song。
  Future<Song> enrichFromDecrypted(Song song, File decryptedFile) async {
    if (!await _fileExists(decryptedFile)) return song;
    try {
      final meta = readMetadata(decryptedFile);
      var title = song.title;
      var artist = song.artist;
      var album = song.album;
      var cover = song.coverUrl;
      var duration = song.duration;
      final metaTitle = meta.title?.trim();
      if (metaTitle != null && metaTitle.isNotEmpty) title = metaTitle;
      final metaArtist = (meta.artist ?? meta.albumArtist)?.trim();
      if (metaArtist != null && metaArtist.isNotEmpty) artist = metaArtist;
      final metaAlbum = meta.album?.trim();
      if (metaAlbum != null && metaAlbum.isNotEmpty) album = metaAlbum;
      duration = (meta.duration?.inSeconds) ?? duration;
      final extractedCover = await _extractCover(meta);
      if (extractedCover.isNotEmpty) cover = extractedCover;
      return song.copyWith(
        title: title,
        artist: artist,
        album: album,
        coverUrl: cover,
        duration: duration,
      );
    } catch (e) {
      debugPrint('[JXMusic] 回填本地歌曲标签失败: $e');
      return song;
    }
  }

  static Future<bool> _fileExists(File file) async {
    try {
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  static String _songId(String path) =>
      'local_${path.hashCode.toRadixString(16)}';

  static String _extensionOf(String path) =>
      p.extension(path).toLowerCase().replaceFirst('.', '');

  static bool _isHiddenPath(String path) {
    try {
      return p.basename(path).startsWith('.');
    } catch (_) {
      return false;
    }
  }

  /// 是否是 `Android/data` / `Android/obb` 系统数据目录（ADR-004 D5 跳过）。
  static bool _isSystemDataPath(String path) {
    try {
      final parts = p.split(p.normalize(path));
      for (var i = 0; i + 1 < parts.length; i++) {
        if (parts[i] == 'Android' &&
            (parts[i + 1] == 'data' || parts[i + 1] == 'obb')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// 去重键：`p.normalize(p.absolute(path))`；Windows 再小写（大小写不敏感）。
  static String _pathKey(String path) {
    try {
      final absolute = p.normalize(p.absolute(path));
      return Platform.isWindows ? absolute.toLowerCase() : absolute;
    } catch (_) {
      return path;
    }
  }

  static String _errorText(Object error) {
    if (error is FileSystemException) {
      final osMessage = error.osError?.message;
      if (osMessage != null && osMessage.isNotEmpty) return osMessage;
      if (error.message.isNotEmpty) return error.message;
    }
    return '$error';
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
      final key =
          '${meta.albumArtist ?? meta.artist ?? ''}|${meta.album ?? ''}';
      final digest = md5
          .convert(utf8.encode(key.isEmpty ? meta.file.path : key))
          .toString();
      final file = File(p.join(dir.path, '$digest.${isPng ? 'png' : 'jpg'}'));
      if (!file.existsSync()) {
        await file.writeAsBytes(bytes, flush: false);
        // 大曲库扫描时封面可能很多：与解密标签封面共用同一数量上限。
        await LocalFormatService.enforceCoverCacheLimit(dir);
      }
      return file.path;
    } catch (e) {
      debugPrint('[JXMusic] 提取本地封面失败: $e');
      return '';
    }
  }
}
