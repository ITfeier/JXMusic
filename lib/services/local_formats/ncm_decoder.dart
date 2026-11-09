import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:music_decoder/music_decoder.dart' as music_decoder;
import 'package:pointycastle/export.dart';

import 'format_decoder.dart';

/// 网易云音乐 NCM 解密适配器。
///
/// NCM 是「容器」：文件头里带 AES 加密的音频密钥与内嵌元数据/封面，
/// 音频段与固定密钥流异或。音频解密由 vendored 的 `packages/music_decoder`
/// 分块流式完成（包未修改）；本类负责：
/// - 文件头魔数校验（`CTENFDAM`）；
/// - **自实现**头部解析（AES-ECB 密钥块/元数据 + keybox 只读头部），供
///   `readTags` 使用 —— 读标签不触发音频解密，也不产生任何输出文件；
/// - 解码进度（按输出字节/音频段总字节）、底层异常中文化与日志留痕。
class NcmDecoder implements EncryptedAudioDecoder {
  static const String _magic = 'CTENFDAM';
  static const int _maxCoverBytes = 8 * 1024 * 1024;
  static const int _maxMetaBytes = 16 * 1024 * 1024;

  /// vendored 包在「无元数据块」时按文件大小推断格式的阈值（>16 MiB 视为 flac）。
  static const int _metadataFormatThreshold = 16 * 1024 * 1024;
  static const int _audioKeyPrefixLength = 'neteasecloudmusic'.length;

  static final Uint8List _coreKey = _hexToBytes(
    '687A4852416D736F356B496E62617857',
  );
  static final Uint8List _metaKey = _hexToBytes(
    '2331346C6A6B5F215C5D2630553C2728',
  );
  static const String _metaTextPrefix = "163 key(Don't modify):";

  /// NCM 内嵌的音频格式来自元数据（通常是 mp3/flac），因此不声明单一输出格式。
  @override
  Set<String> get sourceExtensions => const {'ncm'};

  @override
  String? get outputExtension => null;

  @override
  Future<bool> canDecode(File file) async {
    RandomAccessFile? raf;
    try {
      if (!await file.exists() || await file.length() < 8) {
        return false;
      }
      raf = await file.open();
      final header = await raf.read(8);
      return _isNcmHeader(header);
    } on FileSystemException {
      return false;
    } finally {
      await raf?.close();
    }
  }

  @override
  Future<String> decodeTo(
    File input,
    File outputFile, {
    void Function(double progress)? onProgress,
  }) async {
    if (!await input.exists()) {
      throw const FormatDecodeException('网易云 NCM 文件不存在');
    }
    if (!await canDecode(input)) {
      throw const FormatDecodeException('无法识别的网易云 NCM 加密文件（文件头校验失败）');
    }
    if (input.absolute.path == outputFile.absolute.path) {
      throw const FormatDecodeException('输出文件不能与源文件相同');
    }

    final header = await _readHeaderChecked(input);
    final fileLength = await input.length();
    final audioLength = fileLength - header.audioOffset;
    if (audioLength <= 0) {
      throw const FormatDecodeException('NCM 文件不完整或密钥损坏（音频段为空）');
    }

    final progress = _OutputProgress(
      outputFile: outputFile,
      totalBytes: audioLength,
      callback: onProgress,
    )..start();
    try {
      final result = await music_decoder.NcmDecoder().decodeFile(
        input,
        output: outputFile,
        writeTags: true,
      );
      progress.report(1.0);
      final format = result.metadata.format.trim().toLowerCase();
      return format.isEmpty ? header.format : format;
    } on music_decoder.NcmException catch (error) {
      debugPrint('[NcmDecoder] NcmException: $error');
      throw FormatDecodeException(_describeNcmFailure(error.message));
    } on FormatException catch (error) {
      debugPrint('[NcmDecoder] FormatException: $error');
      throw const FormatDecodeException('NCM 内嵌元数据已损坏，无法解析歌曲信息');
    } on FileSystemException catch (error) {
      debugPrint('[NcmDecoder] FileSystemException: $error');
      throw FormatDecodeException('NCM 解密失败：读写文件出错（${error.message}）');
    } on Exception catch (error) {
      debugPrint('[NcmDecoder] ${error.runtimeType}: $error');
      throw const FormatDecodeException('NCM 解密失败：文件不完整、密钥损坏或加密格式不受支持');
    } finally {
      progress.stop();
    }
  }

  /// 只读文件头标签：不调用解码函数、不写任何文件。
  @override
  Future<EncryptedAudioTags?> readTags(File file) async {
    try {
      final header = await _readHeader(file);
      if (header.title == null &&
          header.album == null &&
          header.artist == null &&
          header.coverBytes == null) {
        return null;
      }
      return EncryptedAudioTags(
        title: header.title,
        artist: header.artist,
        album: header.album,
        coverBytes: header.coverBytes,
      );
    } on FormatDecodeException {
      return null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// decodeTo 用的头部解析：把 FileSystemException / FormatException 也翻成中文。
  Future<_NcmHeader> _readHeaderChecked(File file) async {
    try {
      return await _readHeader(file);
    } on FormatDecodeException {
      rethrow;
    } on FormatException catch (error) {
      debugPrint('[NcmDecoder] 元数据 FormatException: $error');
      throw const FormatDecodeException('NCM 内嵌元数据已损坏，无法解析歌曲信息');
    } on FileSystemException catch (error) {
      debugPrint('[NcmDecoder] FileSystemException: $error');
      throw FormatDecodeException('NCM 解密失败：读写文件出错（${error.message}）');
    }
  }

  /// 自实现 NCM 头部解析：魔数 → 音频密钥块（校验用）→ 元数据 → 封面。
  Future<_NcmHeader> _readHeader(File file) async {
    final fileLength = await file.length();
    final raf = await file.open();
    try {
      final magic = await _readExact(raf, 8, '文件头');
      if (!_isNcmHeader(magic)) {
        throw const FormatDecodeException('无法识别的网易云 NCM 加密文件（文件头校验失败）');
      }
      await raf.setPosition(8 + 2); // 8 字节魔数 + 2 字节固定字段

      final keyLength = _readUint32Le(await _readExact(raf, 4, '音频密钥长度'));
      if (keyLength <= 0 || keyLength > 1024) {
        throw const FormatDecodeException('NCM 文件密钥块长度异常，文件已损坏');
      }
      final keyCipher = await _readExact(raf, keyLength, '音频密钥');
      // 密钥块只做完整性校验：不参与 readTags 的标签读取，也不碰音频。
      final keyPlain = _pkcs7Unpad(
        _aesEcbDecrypt(_coreKey, _xorByte(keyCipher, 0x64)),
        '音频密钥块',
      );
      if (keyPlain.length <= _audioKeyPrefixLength) {
        throw const FormatDecodeException('NCM 文件密钥块已损坏（音频密钥为空）');
      }

      final metaLength = _readUint32Le(await _readExact(raf, 4, '元数据长度'));
      // R-23/R-26 防御：只拦「超过剩余文件」或「超过 16 MiB」；
      // metaLength == 0 是合法形态（无元数据块），与 vendored 包语义一致：
      // 标题等为空、format 按文件大小推断（>16 MiB 视为 flac，否则 mp3）。
      final metaRemaining = fileLength - await raf.position();
      if (metaLength > metaRemaining || metaLength > _maxMetaBytes) {
        throw const FormatDecodeException('NCM 元数据长度异常，文件可能已损坏');
      }

      String format = fileLength > _metadataFormatThreshold ? 'flac' : 'mp3';
      String? title;
      String? album;
      String? artist;
      if (metaLength > 0) {
        final metaCipher = await _readExact(raf, metaLength, '元数据');
        final metaRaw = _xorByte(metaCipher, 0x63);
        if (metaRaw.length < _metaTextPrefix.length) {
          throw const FormatDecodeException('NCM 元数据块过短，文件已损坏');
        }
        final base64Text = utf8
            .decode(
              metaRaw.sublist(_metaTextPrefix.length),
              allowMalformed: true,
            )
            .trim();
        final metaPlain = _pkcs7Unpad(
          _aesEcbDecrypt(_metaKey, base64.decode(base64Text)),
          '元数据块',
        );
        var jsonText = utf8.decode(metaPlain, allowMalformed: true);
        if (jsonText.startsWith('music:')) {
          jsonText = jsonText.substring(6);
        }
        final metadata = jsonDecode(jsonText);
        if (metadata is! Map<String, dynamic>) {
          throw const FormatDecodeException('NCM 内嵌元数据格式异常，无法解析歌曲信息');
        }
        format = _readString(metadata['format'])?.toLowerCase() ?? 'mp3';
        title =
            _readString(metadata['musicName']) ??
            _readString(metadata['title']);
        album = _readString(metadata['album']);
        artist =
            _readArtists(metadata['artist']) ??
            _readArtists(metadata['artists']);
      }

      // 封面：4 字节 CRC32 + 5 字节未知字段 + 4 字节封面长度。
      await raf.setPosition(await raf.position() + 4 + 5);
      final imageSize = _readUint32Le(await _readExact(raf, 4, '封面长度'));
      final imagePosition = await raf.position();
      Uint8List? coverBytes;
      if (imageSize > 0) {
        if (imagePosition + imageSize > fileLength) {
          throw const FormatDecodeException('NCM 封面数据不完整，文件已损坏');
        }
        if (imageSize <= _maxCoverBytes) {
          coverBytes = await _readExact(raf, imageSize, '封面');
        } else {
          // 超过上限不读进内存（R-13），直接定位到音频段。
          await raf.setPosition(imagePosition + imageSize);
        }
      }

      return _NcmHeader(
        format: format,
        title: title,
        album: album,
        artist: artist,
        coverBytes: coverBytes,
        audioOffset: await raf.position(),
      );
    } finally {
      await raf.close();
    }
  }

  bool _isNcmHeader(List<int> header) {
    if (header.length < 8) {
      return false;
    }
    for (var i = 0; i < 8; i++) {
      if (header[i] != _magic.codeUnitAt(i)) {
        return false;
      }
    }
    return true;
  }

  Future<Uint8List> _readExact(
    RandomAccessFile raf,
    int length,
    String what,
  ) async {
    final bytes = await raf.read(length);
    if (bytes.length != length) {
      throw FormatDecodeException('NCM 文件不完整（读取$what时提前结束）');
    }
    return bytes;
  }

  Uint8List _aesEcbDecrypt(Uint8List key, Uint8List data) {
    if (data.isEmpty || data.length % 16 != 0) {
      throw const FormatDecodeException('NCM 文件密钥块已损坏（AES 数据长度非法）');
    }
    final cipher = ECBBlockCipher(AESEngine());
    cipher.init(false, KeyParameter(key));
    final out = Uint8List(data.length);
    for (var offset = 0; offset < data.length; offset += cipher.blockSize) {
      cipher.processBlock(data, offset, out, offset);
    }
    return out;
  }

  Uint8List _pkcs7Unpad(Uint8List data, String what) {
    if (data.isEmpty) {
      throw FormatDecodeException('NCM $what已损坏（填充为空）');
    }
    final pad = data.last;
    if (pad == 0 || pad > 16 || pad > data.length) {
      throw FormatDecodeException('NCM $what已损坏（PKCS7 填充非法）');
    }
    for (var i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) {
        throw FormatDecodeException('NCM $what已损坏（PKCS7 填充非法）');
      }
    }
    return data.sublist(0, data.length - pad);
  }

  String? _readString(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    return null;
  }

  String? _readArtists(Object? value) {
    if (value is! List) {
      return null;
    }
    final artists = <String>[];
    for (final entry in value) {
      if (entry is List && entry.isNotEmpty) {
        final name = _readString(entry.first);
        if (name != null) {
          artists.add(name);
        }
      } else if (entry is String && entry.trim().isNotEmpty) {
        artists.add(entry.trim());
      }
    }
    if (artists.isEmpty) {
      return null;
    }
    return artists.join('/');
  }

  String _describeNcmFailure(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('not found')) {
      return '网易云 NCM 文件不存在';
    }
    if (lower.contains('header') || lower.contains('magic')) {
      return '无法识别的网易云 NCM 加密文件（文件头校验失败）';
    }
    if (lower.contains('output path')) {
      return '输出文件不能与源文件相同';
    }
    if (lower.contains('padding') ||
        lower.contains('aes') ||
        lower.contains('decrypted key') ||
        lower.contains('metadata block')) {
      return 'NCM 文件密钥或元数据已损坏（校验失败）';
    }
    if (lower.contains('unexpected end') ||
        lower.contains('too short') ||
        lower.contains('too small') ||
        lower.contains('empty')) {
      return 'NCM 文件不完整或已损坏（读取密钥/元数据/封面时提前结束）';
    }
    return 'NCM 解密失败：文件不完整、密钥损坏或加密格式不受支持';
  }
}

class _NcmHeader {
  const _NcmHeader({
    required this.format,
    required this.audioOffset,
    this.title,
    this.album,
    this.artist,
    this.coverBytes,
  });

  final String format;
  final int audioOffset;
  final String? title;
  final String? album;
  final String? artist;
  final Uint8List? coverBytes;
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List _xorByte(Uint8List data, int value) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = data[i] ^ value;
  }
  return out;
}

int _readUint32Le(Uint8List bytes) {
  return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
}

/// 解码进度：轮询输出文件长度 / 音频总字节，夹取到 0..1 并保持单调。
///
/// vendored 包不暴露分块回调且未修改包源码（ADR-004 D1），因此用写入进度
/// 近似「已处理音频字节」，完成时由调用方补 1.0。
class _OutputProgress {
  _OutputProgress({
    required this.outputFile,
    required this.totalBytes,
    required this.callback,
  });

  final File outputFile;
  final int totalBytes;
  final void Function(double progress)? callback;
  Timer? _timer;
  double _last = -1;

  void start() {
    report(0.0);
    if (callback == null) {
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      unawaited(_tick());
    });
  }

  Future<void> _tick() async {
    try {
      final written = await outputFile.length();
      if (totalBytes <= 0) {
        return;
      }
      final value = written / totalBytes;
      report(value > 0.99 ? 0.99 : value);
    } on FileSystemException {
      // 输出文件尚未创建或正被写入，忽略本次采样。
    }
  }

  void report(double value) {
    final bounded = value.isNaN ? 0.0 : value.clamp(0.0, 1.0).toDouble();
    if (bounded <= _last) {
      return;
    }
    _last = bounded;
    callback?.call(bounded);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
