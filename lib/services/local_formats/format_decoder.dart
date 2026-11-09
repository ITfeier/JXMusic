import 'dart:io';
import 'dart:typed_data';

/// 加密音频文件解码器统一接口（本地音乐加密格式扩展点）。
///
/// 约定：
/// - 每个解码器只负责一类平台加密格式（NCM / QMC / KGM…），由
///   `LocalFormatService` 按 [sourceExtensions] + [canDecode] 调度；
/// - [decodeTo] 必须分块流式读写，禁止把整个音频文件读进内存；
/// - 解码失败抛 [FormatDecodeException]（带可展示的中文原因）；
/// - 本接口不依赖 Flutter，纯 Dart 单元测试可直接调用。
abstract class EncryptedAudioDecoder {
  /// 负责的源文件扩展名（小写、不含点），例如 `{'ncm'}`、`{'kgm','kgma','vpr'}`。
  Set<String> get sourceExtensions;

  /// 输出音频格式（mp3/flac/ogg/m4a/wav）：
  /// 单格式解码器直接返回；多格式解码器返回 null，以 [decodeTo] 返回值为准。
  String? get outputExtension;

  /// 读文件头/尾魔数，确认确实是本解码器能处理的加密文件。
  Future<bool> canDecode(File file);

  /// 把加密文件解码到 [outputFile]（覆盖写），返回输出音频格式（小写、不含点）。
  /// [onProgress] 传入 0.0–1.0 进度，供 UI 显示解密进度。
  Future<String> decodeTo(
    File input,
    File outputFile, {
    void Function(double progress)? onProgress,
  });

  /// 从加密文件本身可直接读出的标签（例如 NCM 的元数据块）。
  /// 读不到返回 null；不支持返回 null 即可，调用方会回退到文件名解析。
  Future<EncryptedAudioTags?> readTags(File file);
}

/// 加密文件自带的标签；封面以原始字节返回，由调用方落盘缓存。
class EncryptedAudioTags {
  const EncryptedAudioTags({
    this.title,
    this.artist,
    this.album,
    this.coverBytes,
  });

  final String? title;
  final String? artist;
  final String? album;
  final Uint8List? coverBytes;
}

/// 解密失败：message 为可直接展示给用户的中文原因。
class FormatDecodeException implements Exception {
  const FormatDecodeException(this.message);

  final String message;

  @override
  String toString() => message;
}
