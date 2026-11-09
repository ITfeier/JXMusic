import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:music_decoder/music_decoder.dart' as music_decoder;

import 'format_decoder.dart';

/// QQ 音乐 QMC 解密适配器（v1 静态密钥 + v2 尾部 EKey 派生）。
///
/// QMC 文件没有可靠的魔数，只能靠「扩展名 + 文件尾部结构」判断：
/// - v1（qmc0/qmc2/qmc3/tkm/bkc*/hex 扩展名）：256 字节公开静态密钥二次索引异或，无尾包；
/// - v2（mflac/mflac0/mgg/mgg1/qmcflac/qmcogg）：尾部带 EKey（PC 小端长度 /
///   安卓 QTag），派生 TEA-CBC 主密钥后走 Map 或分段 RC4 流密码；
/// - musicex / STag 新版尾部：**不含 EKey**，离线无解，直接给明确中文原因。
///
/// 音频解密由 vendored 的 `packages/music_decoder` 分块流式完成（包未修改）。
/// 解码成功后再嗅探输出容器：vendored 包在「无密钥变体」上可能"成功"返回噪声，
/// 按 ADR-004 D2 禁止把乱码当成功。
class QmcDecoder implements EncryptedAudioDecoder {
  static final Set<String> _supportedExtensions = Set.unmodifiable(
    music_decoder.QmcDecoder.supportedExtensions.map(
      (extension) => extension.toLowerCase(),
    ),
  );

  /// 包内 `qmcExtensionMap` 中版本为 v1 的扩展名：无尾包、静态密钥。
  static const Set<String> _v1Extensions = {
    'qmc0',
    'qmc2',
    'qmc3',
    'bkcmp3',
    'bkcflac',
    'tkm',
    '666c6163',
    '6d7033',
    '6f6767',
    '6d3461',
    '776176',
  };

  static const int _minLegacyKeySize = 16;
  static const int _maxLegacyKeySize = 0x300;
  static const String _noKeyMessage = 'QQ 音乐该文件尾部不含密钥（musicex/STag），暂不支持离线解密';
  static const String _invalidAudioMessage = '解密结果不是有效音频（文件可能已损坏或为不支持的变体）';

  @override
  Set<String> get sourceExtensions => _supportedExtensions;

  /// 一个扩展名对应一种输出格式（由包内映射决定），因此不声明单一输出格式。
  @override
  String? get outputExtension => null;

  @override
  Future<bool> canDecode(File file) async {
    final extension = _extensionOf(file.path);
    if (!_supportedExtensions.contains(extension)) {
      return false;
    }

    RandomAccessFile? raf;
    try {
      if (!await file.exists()) {
        return false;
      }
      final length = await file.length();
      if (length < 8) {
        return false;
      }
      raf = await file.open();
      await raf.setPosition(length - 8);
      final tail = await raf.read(8);
      if (tail.length < 8) {
        return false;
      }
      if (_inspectTail(tail) != _QmcTailKind.none) {
        return true;
      }
      // QMC v1 本来就没有尾包，扩展名即证据。
      return _v1Extensions.contains(extension);
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
    final extension = _extensionOf(input.path);
    if (!_supportedExtensions.contains(extension)) {
      throw FormatDecodeException(
        '不支持的 QQ 音乐加密扩展名：${extension.isEmpty ? '（无扩展名）' : '.$extension'}',
      );
    }
    if (!await input.exists()) {
      throw const FormatDecodeException('QQ 音乐加密文件不存在');
    }
    if (input.absolute.path == outputFile.absolute.path) {
      throw const FormatDecodeException('输出文件不能与源文件相同');
    }

    final length = await input.length();
    if (length < 8) {
      throw const FormatDecodeException('QQ 音乐加密文件不完整（文件过短）');
    }
    final tail = await _readTail(input, length);
    final tailKind = _inspectTail(tail);
    if (tailKind == _QmcTailKind.musicEx || tailKind == _QmcTailKind.sTag) {
      throw const FormatDecodeException(_noKeyMessage);
    }
    if (tailKind == _QmcTailKind.none && !_v1Extensions.contains(extension)) {
      throw const FormatDecodeException(_noKeyMessage);
    }

    final audioSize = _audioSize(length, tail, tailKind);
    if (audioSize <= 0) {
      throw const FormatDecodeException('QQ 音乐加密文件的尾部密钥长度异常，文件已损坏');
    }

    final progress = _OutputProgress(
      outputFile: outputFile,
      totalBytes: audioSize,
      callback: onProgress,
    )..start();
    try {
      await music_decoder.QmcDecoder().decodeFile(input, output: outputFile);
      // R-22：容器嗅探结果优先于扩展名映射（扩展名可能被改错/变体混用）。
      final detectedFormat = await _detectOutputAudioFormat(outputFile);
      if (detectedFormat == null) {
        throw const FormatDecodeException(_invalidAudioMessage);
      }
      progress.report(1.0);
      return detectedFormat;
    } on FormatDecodeException {
      rethrow;
    } on music_decoder.QmcException catch (error) {
      debugPrint('[QmcDecoder] QmcException: $error');
      throw FormatDecodeException(
        _describeQmcFailure(error.message, extension),
      );
    } on Exception catch (error) {
      // QmcCipherException / QmcKeyDecoderException 未被包内公开库导出，这里按基类兜底，
      // 并把原始异常类型与信息写入日志（R-4）。
      if (error is FileSystemException) {
        debugPrint('[QmcDecoder] FileSystemException: $error');
        throw FormatDecodeException('QQ 音乐加密文件解密失败：读写文件出错（${error.message}）');
      }
      debugPrint('[QmcDecoder] ${error.runtimeType}: $error');
      throw FormatDecodeException(
        _describeQmcFailure(error.toString(), extension),
      );
    } finally {
      progress.stop();
    }
  }

  /// QMC 本身不带标签，解密出音频后由调用方读取音频元数据。
  @override
  Future<EncryptedAudioTags?> readTags(File file) async => null;

  /// 解码后容器自检 + 格式识别（ADR-004 D2 / 评审 R-3、R-22）：只读输出前 8 字节。
  ///
  /// 返回嗅探出的音频格式（flac/mp3/ogg/m4a/wav）；不是合法容器返回 null。
  Future<String?> _detectOutputAudioFormat(File outputFile) async {
    RandomAccessFile? raf;
    try {
      raf = await outputFile.open();
      final head = await raf.read(8);
      return _sniffAudioFormat(head);
    } on FileSystemException catch (error) {
      debugPrint('[QmcDecoder] 读取解密结果失败: $error');
      return null;
    } finally {
      await raf?.close();
    }
  }

  String? _sniffAudioFormat(Uint8List head) {
    if (head.length < 4) {
      return null;
    }
    if (_asciiEquals(head, 0, 'fLaC')) {
      return 'flac';
    }
    if (_asciiEquals(head, 0, 'ID3')) {
      return 'mp3';
    }
    if (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
      return 'mp3'; // MPEG 帧同步
    }
    if (_asciiEquals(head, 0, 'OggS')) {
      return 'ogg';
    }
    if (_asciiEquals(head, 0, 'RIFF')) {
      return 'wav';
    }
    if (head.length >= 8 && _asciiEquals(head, 4, 'ftyp')) {
      return 'm4a';
    }
    return null;
  }

  Future<Uint8List> _readTail(File file, int length) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      await raf.setPosition(length - 8);
      return await raf.read(8);
    } on FileSystemException catch (error) {
      debugPrint('[QmcDecoder] 读取文件尾部失败: $error');
      throw const FormatDecodeException('QQ 音乐加密文件不完整（无法读取文件尾部）');
    } finally {
      await raf?.close();
    }
  }

  int _audioSize(int fileLength, Uint8List tail, _QmcTailKind tailKind) {
    switch (tailKind) {
      case _QmcTailKind.qTag:
        final keySize = _readUint32Be(tail, 0);
        return fileLength - keySize - 8;
      case _QmcTailKind.legacyKey:
        final keySize = _readUint32Le(tail, 4);
        return fileLength - keySize - 4;
      case _QmcTailKind.musicEx:
      case _QmcTailKind.sTag:
      case _QmcTailKind.none:
        return fileLength;
    }
  }

  _QmcTailKind _inspectTail(Uint8List tail) {
    if (tail.length < 8) {
      return _QmcTailKind.none;
    }
    if (_asciiEquals(tail, 4, 'STag')) {
      return _QmcTailKind.sTag;
    }
    if (_asciiEquals(tail, 4, 'QTag')) {
      return _QmcTailKind.qTag;
    }
    if (_asciiEquals(tail, 0, 'musicex') && tail[7] == 0) {
      return _QmcTailKind.musicEx;
    }
    final legacyKeySize = _readUint32Le(tail, 4);
    if (legacyKeySize >= _minLegacyKeySize &&
        legacyKeySize < _maxLegacyKeySize) {
      return _QmcTailKind.legacyKey;
    }
    return _QmcTailKind.none;
  }

  bool _asciiEquals(Uint8List bytes, int offset, String text) {
    if (bytes.length < offset + text.length) {
      return false;
    }
    for (var i = 0; i < text.length; i++) {
      if (bytes[offset + i] != text.codeUnitAt(i)) {
        return false;
      }
    }
    return true;
  }

  int _readUint32Le(Uint8List bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }

  int _readUint32Be(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1 || dot == path.length - 1) {
      return '';
    }
    return path.substring(dot + 1).toLowerCase();
  }

  String _describeQmcFailure(String message, String extension) {
    final lower = message.toLowerCase();
    if (lower.contains('not found')) {
      return 'QQ 音乐加密文件不存在';
    }
    if (lower.contains('unsupported qmc extension')) {
      return '不支持的 QQ 音乐加密扩展名：.$extension';
    }
    if (lower.contains('too small')) {
      return 'QQ 音乐加密文件不完整（文件过短）';
    }
    if (lower.contains('musicex')) {
      return _noKeyMessage;
    }
    if (lower.contains('base64') ||
        lower.contains('padding') ||
        lower.contains('tea') ||
        lower.contains('zero check') ||
        lower.contains('origin key') ||
        lower.contains('input length')) {
      return 'QQ 音乐加密密钥已损坏，无法解密（文件不完整或密钥被篡改）';
    }
    if (lower.contains('qtag') ||
        lower.contains('key size') ||
        lower.contains('key terminator') ||
        lower.contains('key data')) {
      return 'QQ 音乐加密文件的尾部密钥结构已损坏';
    }
    if (lower.contains('unexpected end') ||
        lower.contains('unable to read') ||
        lower.contains('footer')) {
      return 'QQ 音乐加密文件不完整（读取尾部密钥时提前结束）';
    }
    return 'QQ 音乐加密文件解密失败：文件不完整或密钥损坏';
  }
}

enum _QmcTailKind { musicEx, sTag, qTag, legacyKey, none }

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
