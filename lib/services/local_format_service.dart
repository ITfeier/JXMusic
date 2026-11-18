import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'local_formats/format_decoder.dart';
import 'local_formats/supported_formats.dart';

/// 本地加密音频的解密编排服务（ADR-004 v1.0 D3）。
///
/// 缓存布局（评审 R-2）：
/// `<应用支持目录>/decrypted_audio/<keyHex>/data.<输出扩展名>`
/// - `keyHex = sha1('v1|<绝对路径>|<sizeBytes>|<mtimeMs>')`（缓存格式版本前缀 v1）；
/// - 输出扩展名解码后才知道，所以命中判定 = `<keyHex>/data.*` 存在且 size > 0；
/// - 先写 `data.<ext>.part`（扩展名未知时 `data.part`）再 rename，异常删除 `.part`；
/// - 启动时清理残留 `*.part` 与空缓存目录；
/// - 同一 key 并发请求复用同一个 Future，无论成功失败都在完成后从 map 移除；
/// - 超过 1.5 GB 或 400 个文件时按 mtime（播放命中 touch）淘汰，跳过 in-flight。
///
/// 其他职责：
/// - [isEncryptedPath] / [platformLabel]：扩展名判断与平台标签；
/// - [playableUrl]：普通格式返回源路径、加密格式返回缓存路径；失败返回 null
///   并把中文原因写入 [lastError]（评审 R-11，供 UI/队列失败提示）；
/// - [readTags] / [saveCoverBytes]：加密格式标签与封面（复用临时目录封面缓存）；
/// - [clearCache] / [cacheSizeBytes] / [cacheFileCount]：缓存清理与统计。
class LocalFormatService {
  LocalFormatService({
    required List<EncryptedAudioDecoder> decoders,
    this.cacheRootProvider,
    this.exists,
    this.tempRootProvider,
    this.maxCacheBytes = defaultMaxCacheBytes,
    this.maxCacheFiles = defaultMaxCacheFiles,
  }) : _decoders = List<EncryptedAudioDecoder>.unmodifiable(decoders);

  /// 缓存上限：1.5 GB。
  static const int defaultMaxCacheBytes = 1536 * 1024 * 1024;

  /// 缓存上限：400 个文件。
  static const int defaultMaxCacheFiles = 400;

  /// 解密缓存目录名（应用支持目录下）。
  static const String cacheDirName = 'decrypted_audio';

  /// 缓存格式版本（解码器算法/公钥表升级时递增，避免命中旧产物）。
  static const String cacheKeyVersion = 'v1';

  /// 封面缓存目录名（临时目录下，和既有封面缓存复用）。
  static const String coverDirName = 'jxmusic_covers';

  /// 封面缓存文件数上限：封面可随时从源文件重新提取，超限按 mtime 淘汰最旧的。
  static const int maxCoverCacheFiles = 400;

  final List<EncryptedAudioDecoder> _decoders;

  /// 缓存根目录来源（默认 `getApplicationSupportDirectory()/decrypted_audio`）。
  final Future<Directory> Function()? cacheRootProvider;

  /// 文件存在性判断（默认 `File(path).existsSync()`），便于单测注入。
  final bool Function(String path)? exists;

  /// 临时根目录来源（默认 `getTemporaryDirectory`，封面缓存用）。
  final Future<Directory> Function()? tempRootProvider;

  /// 缓存容量上限（字节，默认 1.5GB）。
  final int maxCacheBytes;

  /// 缓存文件数上限（默认 400）。
  final int maxCacheFiles;

  /// 最近一次 [playableUrl] 失败的中文原因（成功/普通格式时清空）。
  ///
  /// 并发解析时按 [_lastErrorSongId] 归属：只有「同一首歌」成功时才清空，
  /// 避免歌 A 的失败原因被歌 B 的成功抹掉（竞态收窄）。
  String? lastError;
  String? _lastErrorSongId;

  /// 同 key 正在解密的 Future（并发合并，避免同一首歌重复解密）。
  final Map<String, Future<File>> _pending = <String, Future<File>>{};

  /// 同 key 的进度回调（合并后的请求也能收到进度）。
  final Map<String, List<void Function(double)>> _progressListeners =
      <String, List<void Function(double)>>{};

  /// 正在解密的 key 集合：清理缓存/淘汰时跳过。
  final Set<String> _inFlightKeys = <String>{};

  Directory? _cacheDirCache;
  Directory? _coverDirCache;
  bool _cleanedUp = false;

  /// 路径的音频扩展名（小写、无点）。
  String extensionOf(String path) =>
      p.extension(path).toLowerCase().replaceFirst('.', '');

  /// 是否是加密格式（需要解密才能播放）。
  bool isEncryptedPath(String path) =>
      LocalAudioFormats.isEncrypted(extensionOf(path));

  /// 是否是可以直接交给播放器的普通格式。
  bool isCommonPath(String path) =>
      LocalAudioFormats.isCommon(extensionOf(path));

  /// 加密平台标签（如「网易云加密」）；普通/未知格式返回 null。
  String? platformLabel(String path) =>
      LocalAudioFormats.platformLabel(extensionOf(path));

  /// 按扩展名找到负责的解密器；没有返回 null。
  EncryptedAudioDecoder? decoderForPath(String path) {
    final ext = extensionOf(path);
    if (ext.isEmpty || !LocalAudioFormats.isEncrypted(ext)) return null;
    for (final decoder in _decoders) {
      if (decoder.sourceExtensions.map((e) => e.toLowerCase()).contains(ext)) {
        return decoder;
      }
    }
    return null;
  }

  /// 读取加密文件自带的标签（NCM 等支持；不支持/失败返回 null）。
  Future<EncryptedAudioTags?> readTags(String path) async {
    final decoder = decoderForPath(path);
    if (decoder == null) return null;
    try {
      return await decoder.readTags(File(path));
    } catch (e) {
      debugPrint('[JXMusic] 读取加密标签失败($path): $e');
      return null;
    }
  }

  /// 把封面字节落到临时目录 `jxmusic_covers`（md5 命名），返回文件路径。
  ///
  /// 新写入文件后执行数量淘汰（[maxCoverCacheFiles]），防止大曲库扫描时
  /// 封面缓存无限增长（封面可随时从源文件重新提取，淘汰无损失）。
  Future<String?> saveCoverBytes(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    try {
      final dir = await _coverDir();
      if (dir == null) return null;
      final digest = md5.convert(bytes).toString();
      final file = File(p.join(dir.path, '$digest.${_imageExtension(bytes)}'));
      if (!await file.exists()) {
        await file.writeAsBytes(bytes, flush: false);
        await enforceCoverCacheLimit(dir);
      }
      return file.path;
    } catch (e) {
      debugPrint('[JXMusic] 保存加密封面失败: $e');
      return null;
    }
  }

  /// 封面缓存数量淘汰：超过 [maxFiles] 按 mtime 删最旧的。
  ///
  /// 公开静态：`jxmusic_covers` 同时被本地扫描（local_music）与解密标签
  /// （saveCoverBytes）写入，两处共用同一套上限。
  static Future<void> enforceCoverCacheLimit(
    Directory dir, {
    int maxFiles = maxCoverCacheFiles,
  }) async {
    try {
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) files.add(entity);
      }
      if (files.length <= maxFiles) return;
      final stated = <({File file, DateTime modified})>[];
      for (final file in files) {
        try {
          stated.add((file: file, modified: (await file.stat()).modified));
        } catch (_) {}
      }
      stated.sort((a, b) => a.modified.compareTo(b.modified));
      var excess = files.length - maxFiles;
      for (final entry in stated) {
        if (excess <= 0) break;
        try {
          if (await entry.file.exists()) await entry.file.delete();
          excess--;
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[JXMusic] 淘汰封面缓存失败: $e');
    }
  }

  /// 确保 [song] 指向的加密文件已解密到缓存并返回缓存文件。
  ///
  /// - 普通格式直接返回源文件；
  /// - 命中 `<keyHex>/data.*` 直接返回（并 touch mtime 作为访问时间）；
  /// - 同一源文件的并发请求合并为一次解密（失败后不缓存，可重试）；
  /// - 失败抛 [FormatDecodeException]（中文原因），且不会留下 `.part` 半截文件。
  Future<File> ensureDecrypted(
    Song song, {
    void Function(double progress)? onProgress,
  }) async {
    final rawPath = song.audioUrl;
    if (rawPath == null || rawPath.trim().isEmpty) {
      throw const FormatDecodeException('本地文件路径缺失，无法解密播放');
    }
    final path = rawPath.trim();
    if (!_pathExists(path)) {
      throw FormatDecodeException('文件不存在或无法访问：$path');
    }
    if (!isEncryptedPath(path)) return File(path);

    final decoder = decoderForPath(path);
    if (decoder == null) {
      final ext = extensionOf(path).toUpperCase();
      throw FormatDecodeException('无法识别的 $ext 加密文件（暂不支持该格式的解密）');
    }

    await _ensureCleanupOnce();

    final source = File(path);
    final stat = await _statOrNull(source);
    if (stat == null) {
      throw FormatDecodeException('无法读取文件信息：$path');
    }
    final key = cacheKeyFor(path, stat.size, stat.modified);

    // 同一文件已在解密：复用同一个 Future，并挂上本次进度回调。
    final pending = _pending[key];
    if (pending != null) {
      if (onProgress != null) {
        (_progressListeners[key] ??= <void Function(double)>[]).add(onProgress);
      }
      return pending;
    }

    if (onProgress != null) {
      (_progressListeners[key] ??= <void Function(double)>[]).add(onProgress);
    }
    _inFlightKeys.add(key);
    final future = _decodeToCache(source: source, decoder: decoder, key: key);
    _pending[key] = future;
    // 无论成功失败，完成后都从并发 map / in-flight 集合移除（失败不永久缓存）。
    unawaited(
      future.then<void>(
        (_) => _finishKey(key),
        onError: (Object error, StackTrace stackTrace) => _finishKey(key),
      ),
    );
    return future;
  }

  /// 供播放器 urlResolver 使用：普通格式返回源路径，加密格式返回缓存文件路径。
  ///
  /// 失败返回 null 并写入 [lastError]（中文原因），调用方不得把密文路径交给播放器。
  Future<String?> playableUrl(Song song) async {
    // 注意：不要在入口清空 lastError——并发解析另一首歌时会把上一首的
    // 失败原因抹掉；失败写入、同曲成功清空，见 _clearErrorIfSame。
    final rawPath = song.audioUrl;
    if (rawPath == null || rawPath.trim().isEmpty) {
      lastError = '本地文件路径缺失，无法解密播放';
      _lastErrorSongId = song.globalId;
      return null;
    }
    final path = rawPath.trim();
    if (!isEncryptedPath(path)) {
      _clearErrorIfSame(song);
      return path;
    }
    try {
      final file = await ensureDecrypted(song);
      _clearErrorIfSame(song);
      return file.path;
    } on FormatDecodeException catch (e) {
      lastError = e.message;
      _lastErrorSongId = song.globalId;
      debugPrint('[JXMusic] 解密失败（${song.title}）：${e.message}');
      return null;
    } catch (e) {
      lastError = '解密失败：$e';
      _lastErrorSongId = song.globalId;
      debugPrint('[JXMusic] 解密异常（${song.title}）：$e');
      return null;
    }
  }

  void _clearErrorIfSame(Song song) {
    if (_lastErrorSongId == song.globalId) {
      lastError = null;
      _lastErrorSongId = null;
    }
  }

  /// 计算缓存 key（十六进制 sha1），格式：`sha1('v1|<绝对路径>|<sizeBytes>|<mtimeMs>')`。
  ///
  /// 公开静态方法便于单测直接校验缓存键规则（评审 R-2/R-12）。
  static String cacheKeyFor(
    String sourcePath,
    int sizeBytes,
    DateTime modified,
  ) {
    final absolute = _absolutePath(sourcePath);
    final mtimeMs = modified.millisecondsSinceEpoch;
    return sha1
        .convert(utf8.encode('$cacheKeyVersion|$absolute|$sizeBytes|$mtimeMs'))
        .toString();
  }

  /// 解密缓存目录（不存在时创建；首次调用会清理残留 `.part`/空目录）。
  Future<Directory> cacheDirectory() async {
    await _ensureCleanupOnce();
    return _resolveCacheDir(create: true);
  }

  /// 缓存占用字节数（只统计最终 `data.*` 产物，不含 `.part`）。
  Future<int> cacheSizeBytes() async {
    await _ensureCleanupOnce();
    final entries = await _cacheEntries();
    return entries.fold<int>(0, (sum, entry) => sum + entry.size);
  }

  /// 缓存文件数（只统计最终 `data.*` 产物，不含 `.part`）。
  Future<int> cacheFileCount() async {
    await _ensureCleanupOnce();
    return (await _cacheEntries()).length;
  }

  /// 清空解密缓存，返回释放的字节数。
  ///
  /// [keepPath] 传入「正在播放的缓存文件路径」时跳过该项；正在解密的 key 也跳过。
  Future<int> clearCache({String? keepPath}) async {
    await _ensureCleanupOnce();
    var removed = 0;
    try {
      final root = await _cacheDirIfExists();
      if (root == null) return 0;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final key = p.basename(entity.path);
        if (_inFlightKeys.contains(key)) continue;
        final files = <File>[];
        await for (final child in entity.list(followLinks: false)) {
          if (child is File) files.add(child);
        }
        for (final file in files) {
          if (keepPath != null && _samePath(file.path, keepPath)) continue;
          try {
            removed += (await file.stat()).size;
            await file.delete();
          } catch (_) {}
        }
        await _deleteEmptyDir(entity);
      }
    } catch (e) {
      debugPrint('[JXMusic] 清理解密缓存失败: $e');
    }
    return removed;
  }

  // ---------------------------------------------------------------------------
  // 解密与缓存
  // ---------------------------------------------------------------------------

  Future<File> _decodeToCache({
    required File source,
    required EncryptedAudioDecoder decoder,
    required String key,
  }) async {
    final root = await _resolveCacheDir(create: true);
    final keyDir = Directory(p.join(root.path, key));

    final cached = await _findCachedData(keyDir);
    if (cached != null) {
      await _touch(cached);
      _reportProgress(key, 1);
      await _enforceCacheLimit(keepPath: cached.path);
      return cached;
    }

    if (!await keyDir.exists()) {
      await keyDir.create(recursive: true);
    }
    final guessedExt = _normalizeExtension(decoder.outputExtension);
    final part = File(
      p.join(
        keyDir.path,
        guessedExt == null ? 'data.part' : 'data.$guessedExt.part',
      ),
    );
    await _deleteQuietly(part);
    try {
      _reportProgress(key, 0);
      final decodedExt = await decoder.decodeTo(
        source,
        part,
        onProgress: (progress) => _reportProgress(key, progress),
      );
      if (!await part.exists()) {
        throw const FormatDecodeException('解密失败：未生成输出文件');
      }
      final ext =
          _normalizeExtension(decodedExt) ??
          _normalizeExtension(decoder.outputExtension) ??
          'bin';
      final target = File(p.join(keyDir.path, 'data.$ext'));
      if (await target.exists()) {
        await _deleteQuietly(target);
      }
      await part.rename(target.path);
      await _touch(target);
      _reportProgress(key, 1);
      await _enforceCacheLimit(keepPath: target.path);
      return target;
    } on FormatDecodeException {
      await _deleteQuietly(part);
      await _deleteEmptyDir(keyDir);
      rethrow;
    } catch (e) {
      await _deleteQuietly(part);
      await _deleteEmptyDir(keyDir);
      throw FormatDecodeException('解密失败：$e');
    }
  }

  void _finishKey(String key) {
    _pending.remove(key);
    _inFlightKeys.remove(key);
    _progressListeners.remove(key);
  }

  void _reportProgress(String key, double value) {
    final listeners = _progressListeners[key];
    if (listeners == null || listeners.isEmpty) return;
    final clamped = value.clamp(0.0, 1.0).toDouble();
    for (final listener in List<void Function(double)>.of(listeners)) {
      try {
        listener(clamped);
      } catch (_) {}
    }
  }

  Future<void> _ensureCleanupOnce() async {
    if (_cleanedUp) return;
    _cleanedUp = true;
    try {
      final root = await _resolveCacheDir(create: true);
      await for (final entity in root.list(followLinks: false)) {
        if (entity is File) {
          if (entity.path.endsWith('.part')) await _deleteQuietly(entity);
          continue;
        }
        if (entity is! Directory) continue;
        final key = p.basename(entity.path);
        if (_inFlightKeys.contains(key)) continue;
        var hasData = false;
        await for (final child in entity.list(followLinks: false)) {
          if (child is! File) continue;
          if (child.path.endsWith('.part')) {
            await _deleteQuietly(child);
            continue;
          }
          if (p.basename(child.path).startsWith('data.')) hasData = true;
        }
        if (!hasData) await _deleteEmptyDir(entity);
      }
    } catch (e) {
      debugPrint('[JXMusic] 清理解密缓存残留失败: $e');
    }
  }

  Future<File?> _findCachedData(Directory keyDir) async {
    try {
      if (!await keyDir.exists()) return null;
      await for (final entity in keyDir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith('data.')) continue;
        if (name.endsWith('.part')) continue;
        if ((await entity.stat()).size > 0) return entity;
      }
    } catch (_) {}
    return null;
  }

  Future<Directory> _resolveCacheDir({required bool create}) async {
    final cached = _cacheDirCache;
    if (cached != null) {
      if (create && !await cached.exists()) {
        await cached.create(recursive: true);
      }
      return cached;
    }
    final provider = cacheRootProvider;
    final dir = provider != null
        ? await provider()
        : Directory(
            p.join((await getApplicationSupportDirectory()).path, cacheDirName),
          );
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDirCache = dir;
    return dir;
  }

  Future<Directory?> _cacheDirIfExists() async {
    final cached = _cacheDirCache;
    if (cached != null) return cached;
    try {
      final provider = cacheRootProvider;
      final dir = provider != null
          ? await provider()
          : Directory(
              p.join(
                (await getApplicationSupportDirectory()).path,
                cacheDirName,
              ),
            );
      if (!await dir.exists()) return null;
      _cacheDirCache = dir;
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// 列出所有最终缓存产物（`<keyHex>/data.*`，size > 0）。
  Future<List<({File file, String key, int size, DateTime modified})>>
  _cacheEntries() async {
    final root = await _cacheDirIfExists();
    if (root == null) return const [];
    final entries = <({File file, String key, int size, DateTime modified})>[];
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final key = p.basename(entity.path);
        await for (final child in entity.list(followLinks: false)) {
          if (child is! File) continue;
          final name = p.basename(child.path);
          if (!name.startsWith('data.') || name.endsWith('.part')) continue;
          try {
            final stat = await child.stat();
            if (stat.size <= 0) continue;
            entries.add((
              file: child,
              key: key,
              size: stat.size,
              modified: stat.modified,
            ));
          } catch (_) {}
        }
      }
    } catch (_) {}
    return entries;
  }

  Future<Directory?> _coverDir() async {
    final cached = _coverDirCache;
    if (cached != null) return cached;
    try {
      final provider = tempRootProvider;
      final root = provider != null
          ? await provider()
          : await getTemporaryDirectory();
      final dir = Directory(p.join(root.path, coverDirName));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _coverDirCache = dir;
      return dir;
    } catch (e) {
      debugPrint('[JXMusic] 创建封面缓存目录失败: $e');
      return null;
    }
  }

  Future<void> _enforceCacheLimit({String? keepPath}) async {
    try {
      final entries = await _cacheEntries();
      if (entries.isEmpty) return;
      var totalBytes = entries.fold<int>(0, (sum, entry) => sum + entry.size);
      var count = entries.length;
      if (totalBytes <= maxCacheBytes && count <= maxCacheFiles) return;

      final sorted = List.of(entries)
        ..sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in sorted) {
        if (totalBytes <= maxCacheBytes && count <= maxCacheFiles) break;
        if (_inFlightKeys.contains(entry.key)) continue;
        if (keepPath != null && _samePath(entry.file.path, keepPath)) continue;
        await _deleteQuietly(entry.file);
        totalBytes -= entry.size;
        count--;
        await _deleteEmptyDir(entry.file.parent);
      }
    } catch (e) {
      debugPrint('[JXMusic] 淘汰解密缓存失败: $e');
    }
  }

  bool _pathExists(String path) {
    final checker = exists;
    if (checker != null) {
      try {
        return checker(path);
      } catch (_) {
        return false;
      }
    }
    return _existsFile(path);
  }

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {}
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _deleteEmptyDir(Directory dir) async {
    try {
      if (!await dir.exists()) return;
      await for (final _ in dir.list(followLinks: false)) {
        return;
      }
      await dir.delete();
    } catch (_) {}
  }

  static Future<FileStat?> _statOrNull(File file) async {
    try {
      return await file.stat();
    } catch (_) {
      return null;
    }
  }

  static bool _existsFile(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static String? _normalizeExtension(String? ext) {
    final normalized = (ext ?? '').trim().toLowerCase().replaceAll('.', '');
    return normalized.isEmpty ? null : normalized;
  }

  static String _absolutePath(String path) {
    try {
      return p.normalize(p.absolute(path));
    } catch (_) {
      return path;
    }
  }

  static bool _samePath(String a, String b) {
    try {
      final na = p.normalize(a);
      final nb = p.normalize(b);
      return Platform.isWindows
          ? na.toLowerCase() == nb.toLowerCase()
          : na == nb;
    } catch (_) {
      return a == b;
    }
  }

  static String _imageExtension(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'jpg';
    }
    return 'jpg';
  }
}
