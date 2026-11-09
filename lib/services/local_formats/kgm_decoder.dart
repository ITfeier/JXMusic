import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'format_decoder.dart';

/// 酷狗 KGM / KGMA / VPR 解码器（纯 Dart 移植，算法参考 MIT 的 `kgm.js`）。
///
/// 文件结构（偏移均为字节）：
/// - `0x00` 16：magic，`KGM` 或 `VPR`；
/// - `0x10` 4：音频起始偏移（小端，正常为 1024）；
/// - `0x14` 4：加密版本（小端），`5` 表示 KGG（密钥在客户端，离线不可解）；
/// - `0x1C` 16：crypto_test 自检材料，直接作为私钥主体；
/// - `1024` 起：加密音频数据（按 16 字节一块连续编号）。
///
/// 解密公式（与 `kgm.js` 一致）：
/// ```
/// 明文 = scramble(密文 ^ ownKey[ownIdx]) ^ scramble(pubValue ^ MEND[pubIdx])
/// scramble(v) = v ^ ((v & 0x0F) << 4)
/// ownKey      = crypto_test(16 字节) + 0x00 → 17 字节
/// pubValue    = pubKey[块号]
/// phase       = 块号 % 17
/// ownIdx      = (phase * 16 + 列号) % 17
/// pubIdx      = (phase * 16 + 列号) % 272
/// ```
///
/// 公钥表 `assets/kugou_key.bin` 每 1 字节覆盖 16 字节音频（8 MB 表覆盖约
/// 128 MB 音频），因此一次载入后即可按块号随机索引；音频本身按 16 KB 分块
/// 流式解密，不整读进内存。
///
/// `.kgg`（cryptoVersion == 5）与 KGM 共用 magic：本解码器把它纳入
/// [sourceExtensions] 以便扫描时能识别并给出「暂不支持」提示，但 [decodeTo]
/// 会直接抛 [FormatDecodeException]，不做解密。
class KgmDecoder implements EncryptedAudioDecoder {
  /// [pubKeyLoader] 默认从 Flutter asset 读取公钥表；测试可注入 `File` 读取。
  KgmDecoder({Future<Uint8List> Function()? pubKeyLoader})
      : _pubKeyLoader = pubKeyLoader ?? _loadAssetPubKey;

  /// 文件头固定长度。
  static const int headerLen = 1024;

  /// 私钥长度：crypto_test 16 字节 + 尾部 `0x00`。
  static const int ownKeyLen = 17;

  /// 每块密文/明文字节数。
  static const int blockSize = 16;

  /// 相位周期（与私钥长度一致）。
  static const int phasePeriod = 17;

  /// MEND 常量表长度（17 相位 × 16 列）。
  static const int mendTableLen = 272;

  /// 音频读取块大小（16 KB，是 [blockSize] 的整数倍，保证块边界对齐）。
  static const int readChunkSize = 16 * 1024;

  /// 公钥表 asset 路径。
  static const String pubKeyAssetPath = 'assets/kugou_key.bin';

  /// KGM 文件 magic（16 字节）。
  static const List<int> kgmMagic = <int>[
    0x7c, 0xd5, 0x32, 0xeb, 0x86, 0x02, 0x7f, 0x4b,
    0xa8, 0xaf, 0xa6, 0x8e, 0x0f, 0xff, 0x99, 0x14,
  ];

  /// VPR 文件 magic（16 字节）。
  static const List<int> vprMagic = <int>[
    0x05, 0x28, 0xbc, 0x96, 0xe9, 0xe4, 0x5a, 0x43,
    0x91, 0xaa, 0xbd, 0xd0, 0x7a, 0xf5, 0x36, 0x31,
  ];

  /// 公开的 MEND 表（272 字节常量，与 kgm.js / kgm-py 一致）。
  static final Uint8List _mendTable = Uint8List.fromList(const <int>[
    0xB8, 0xD5, 0x3D, 0xB2, 0xE9, 0xAF, 0x78, 0x8C, 0x83, 0x33, 0x71, 0x51, 0x76, 0xA0, 0xCD, 0x37,
    0x2F, 0x3E, 0x35, 0x8D, 0xA9, 0xBE, 0x98, 0xB7, 0xE7, 0x8C, 0x22, 0xCE, 0x5A, 0x61, 0xDF, 0x68,
    0x69, 0x89, 0xFE, 0xA5, 0xB6, 0xDE, 0xA9, 0x77, 0xFC, 0xC8, 0xBD, 0xBD, 0xE5, 0x6D, 0x3E, 0x5A,
    0x36, 0xEF, 0x69, 0x4E, 0xBE, 0xE1, 0xE9, 0x66, 0x1C, 0xF3, 0xD9, 0x02, 0xB6, 0xF2, 0x12, 0x9B,
    0x44, 0xD0, 0x6F, 0xB9, 0x35, 0x89, 0xB6, 0x46, 0x6D, 0x73, 0x82, 0x06, 0x69, 0xC1, 0xED, 0xD7,
    0x85, 0xC2, 0x30, 0xDF, 0xA2, 0x62, 0xBE, 0x79, 0x2D, 0x62, 0x62, 0x3D, 0x0D, 0x7E, 0xBE, 0x48,
    0x89, 0x23, 0x02, 0xA0, 0xE4, 0xD5, 0x75, 0x51, 0x32, 0x02, 0x53, 0xFD, 0x16, 0x3A, 0x21, 0x3B,
    0x16, 0x0F, 0xC3, 0xB2, 0xBB, 0xB3, 0xE2, 0xBA, 0x3A, 0x3D, 0x13, 0xEC, 0xF6, 0x01, 0x45, 0x84,
    0xA5, 0x70, 0x0F, 0x93, 0x49, 0x0C, 0x64, 0xCD, 0x31, 0xD5, 0xCC, 0x4C, 0x07, 0x01, 0x9E, 0x00,
    0x1A, 0x23, 0x90, 0xBF, 0x88, 0x1E, 0x3B, 0xAB, 0xA6, 0x3E, 0xC4, 0x73, 0x47, 0x10, 0x7E, 0x3B,
    0x5E, 0xBC, 0xE3, 0x00, 0x84, 0xFF, 0x09, 0xD4, 0xE0, 0x89, 0x0F, 0x5B, 0x58, 0x70, 0x4F, 0xFB,
    0x65, 0xD8, 0x5C, 0x53, 0x1B, 0xD3, 0xC8, 0xC6, 0xBF, 0xEF, 0x98, 0xB0, 0x50, 0x4F, 0x0F, 0xEA,
    0xE5, 0x83, 0x58, 0x8C, 0x28, 0x2C, 0x84, 0x67, 0xCD, 0xD0, 0x9E, 0x47, 0xDB, 0x27, 0x50, 0xCA,
    0xF4, 0x63, 0x63, 0xE8, 0x97, 0x7F, 0x1B, 0x4B, 0x0C, 0xC2, 0xC1, 0x21, 0x4C, 0xCC, 0x58, 0xF5,
    0x94, 0x52, 0xA3, 0xF3, 0xD3, 0xE0, 0x68, 0xF4, 0x00, 0x23, 0xF3, 0x5E, 0x0A, 0x7B, 0x93, 0xDD,
    0xAB, 0x12, 0xB2, 0x13, 0xE8, 0x84, 0xD7, 0xA7, 0x9F, 0x0F, 0x32, 0x4C, 0x55, 0x1D, 0x04, 0x36,
    0x52, 0xDC, 0x03, 0xF3, 0xF9, 0x4E, 0x42, 0xE9, 0x3D, 0x61, 0xEF, 0x7C, 0xB6, 0xB3, 0x93, 0x50,
  ]);

  /// (phase, col) → 私钥下标。与块号无关，预先算好避免每字节取模。
  static final Uint8List _ownKeyIndex = _buildOwnKeyIndex();

  /// (phase, col) → MEND 表下标。与块号无关，预先算好避免每字节取模。
  static final Uint16List _mendIndex = _buildMendIndex();

  final Future<Uint8List> Function() _pubKeyLoader;

  /// 公钥表只成功载入一次（8 MB，避免每个文件重复读）。
  Uint8List? _cachedPubKey;

  /// 并发解码时合并同一次公钥表加载。
  Future<Uint8List>? _pendingPubKey;

  @override
  Set<String> get sourceExtensions =>
      const <String>{'kgm', 'kgma', 'vpr', 'kgg'};

  @override
  String? get outputExtension => null;

  @override
  Future<bool> canDecode(File file) async {
    try {
      // 轻量校验：只取文件长度 + 前 16 字节 magic，不读音频。
      // 长度不足 1024 字节头 + 1 块音频（1040）的文件不可能解出音频。
      if (await file.length() < headerLen + kgmMagic.length) return false;
      final source = await file.open();
      try {
        final head = await source.read(kgmMagic.length);
        return _matchesMagic(head);
      } finally {
        await source.close();
      }
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<String> decodeTo(
    File input,
    File outputFile, {
    void Function(double progress)? onProgress,
  }) async {
    final fileLength = await input.length();
    if (fileLength < kgmMagic.length) {
      throw const FormatDecodeException('文件不完整或密钥损坏（文件太小）');
    }

    final source = await input.open();
    RandomAccessFile? target;
    try {
      final header = await _readHeader(source);
      if (!_matchesMagic(header)) {
        throw const FormatDecodeException('不是酷狗 KGM/VPR 加密文件（文件头不匹配）');
      }
      if (header.length < headerLen) {
        throw const FormatDecodeException('文件不完整或密钥损坏（文件头不足 1024 字节）');
      }

      final headerView = ByteData.sublistView(header);
      final audioOffset = headerView.getUint32(0x10, Endian.little);
      final cryptoVersion = headerView.getUint32(0x14, Endian.little);

      if (cryptoVersion == 5) {
        throw const FormatDecodeException('酷狗 KGG 格式需要客户端密钥，暂不支持离线解密');
      }
      if (audioOffset < headerLen || audioOffset >= fileLength) {
        throw FormatDecodeException('音频起始偏移异常：$audioOffset（文件 $fileLength 字节）');
      }

      // 私钥 = crypto_test 16 字节 + 0x00 → 17 字节。
      final ownKey = Uint8List(ownKeyLen);
      ownKey.setRange(0, 16, header, 0x1c);

      final pubKey = await _loadPubKey();
      final audioLength = fileLength - audioOffset;
      final blockCount = (audioLength + blockSize - 1) ~/ blockSize;
      if (blockCount > pubKey.length) {
        throw const FormatDecodeException('文件过大，超出酷狗公钥表覆盖范围');
      }

      await source.setPosition(audioOffset);
      target = await outputFile.open(mode: FileMode.write);

      final encrypted = Uint8List(readChunkSize);
      final plain = Uint8List(readChunkSize);
      var processed = 0;
      String? format;
      onProgress?.call(0.0);

      while (true) {
        final read = await source.readInto(encrypted);
        if (read <= 0) break;
        _decryptChunk(encrypted, read, processed, plain, ownKey, pubKey);
        await target.writeFrom(plain, 0, read);
        format ??= _sniffFormat(Uint8List.sublistView(plain, 0, read));
        processed += read;
        onProgress?.call(processed / audioLength);
      }

      await target.close();
      target = null;

      if (format == null) {
        throw const FormatDecodeException(
          '解密结果不是有效音频（文件可能已损坏或为不支持的变体）',
        );
      }
      onProgress?.call(1.0);
      return format;
    } finally {
      if (target != null) await target.close();
      await source.close();
    }
  }

  @override
  Future<EncryptedAudioTags?> readTags(File file) async => null;

  /// 纯算法解密一段音频密文（不解析文件头、不做输出格式嗅探）。
  ///
  /// 供测试与算法复核使用（例如跨语言黄金向量对拍）；正式播放链路由
  /// [decodeTo] 完成。参数：
  /// - [cryptoTest16]：文件头 `[0x1c,0x2c)` 的 16 字节自检材料；
  /// - [pubKey]：公钥表，长度须覆盖本段音频块数；
  /// - [startPosition]：本段首字节在音频数据内的全局字节偏移（整段解密传 0）。
  ///
  /// 公钥表覆盖不足时抛 [FormatDecodeException]；参数非法抛 [ArgumentError]。
  static Uint8List decryptAudioBytes(
    Uint8List encrypted, {
    required List<int> cryptoTest16,
    required Uint8List pubKey,
    int startPosition = 0,
  }) {
    if (cryptoTest16.length != 16) {
      throw ArgumentError.value(cryptoTest16.length, 'cryptoTest16', '必须为 16 字节');
    }
    if (startPosition < 0) {
      throw ArgumentError.value(startPosition, 'startPosition', '不能为负数');
    }
    final endPosition = startPosition + encrypted.length;
    final blockCount = (endPosition + blockSize - 1) ~/ blockSize;
    if (blockCount > pubKey.length) {
      throw const FormatDecodeException('文件过大，超出酷狗公钥表覆盖范围');
    }
    final ownKey = Uint8List(ownKeyLen);
    ownKey.setRange(0, cryptoTest16.length, cryptoTest16);
    final plain = Uint8List(encrypted.length);
    _decryptChunk(encrypted, encrypted.length, startPosition, plain, ownKey, pubKey);
    return plain;
  }

  /// 读取最多 [headerLen] 字节文件头（对短文件返回实际长度）。
  Future<Uint8List> _readHeader(RandomAccessFile source) async {
    final buffer = Uint8List(headerLen);
    var total = 0;
    while (total < headerLen) {
      final read = await source.readInto(buffer, total, headerLen);
      if (read <= 0) break;
      total += read;
    }
    return Uint8List.sublistView(buffer, 0, total);
  }

  /// 解密一个读入块。[startPosition] 是该块首字节在音频数据中的全局下标。
  ///
  /// 块号全局连续：`块号 = 全局字节下标 ~/ 16`，因此跨 16 KB I/O 块时
  /// 相位、私钥索引、MEND 索引都与整文件解密完全一致。
  static void _decryptChunk(
    Uint8List encrypted,
    int length,
    int startPosition,
    Uint8List plain,
    Uint8List ownKey,
    Uint8List pubKey,
  ) {
    final mask = Uint8List(blockSize);
    var index = 0;
    var position = startPosition;
    while (index < length) {
      final blockIdx = position ~/ blockSize;
      final col = position % blockSize;
      final phase = blockIdx % phasePeriod;
      final base = phase * blockSize;
      final pubValue = pubKey[blockIdx];

      // 这一块 16 列各自的公钥掩码。块内只算一次，避免每字节重复计算。
      for (var c = 0; c < blockSize; c++) {
        mask[c] = _scramble(pubValue ^ _mendTable[_mendIndex[base + c]]);
      }

      final remaining = length - index;
      final inBlock = blockSize - col;
      final take = remaining < inBlock ? remaining : inBlock;
      for (var c = 0; c < take; c++) {
        final idx = base + col + c;
        plain[index + c] = _scramble(encrypted[index + c] ^ ownKey[_ownKeyIndex[idx]]) ^
            mask[col + c];
      }
      index += take;
      position += take;
    }
  }

  /// 公钥表加载：成功一次后缓存；并发请求共享同一次加载。
  Future<Uint8List> _loadPubKey() async {
    final cached = _cachedPubKey;
    if (cached != null) return cached;
    final pending = _pendingPubKey;
    if (pending != null) return pending;
    final future = _loadPubKeyOnce();
    _pendingPubKey = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingPubKey, future)) _pendingPubKey = null;
    }
  }

  Future<Uint8List> _loadPubKeyOnce() async {
    final Uint8List key;
    try {
      key = await _pubKeyLoader();
    } on FormatDecodeException {
      rethrow;
    } catch (_) {
      throw const FormatDecodeException(
        '酷狗公钥表缺失（assets/kugou_key.bin），无法解密',
      );
    }
    if (key.isEmpty) {
      throw const FormatDecodeException(
        '酷狗公钥表缺失（assets/kugou_key.bin），无法解密',
      );
    }
    _cachedPubKey = key;
    return key;
  }

  /// 默认公钥表加载器：从 Flutter asset 读取（需在 pubspec 声明）。
  static Future<Uint8List> _loadAssetPubKey() async {
    final data = await rootBundle.load(pubKeyAssetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  static Uint8List _buildOwnKeyIndex() {
    final table = Uint8List(phasePeriod * blockSize);
    for (var phase = 0; phase < phasePeriod; phase++) {
      for (var col = 0; col < blockSize; col++) {
        table[phase * blockSize + col] = (phase * blockSize + col) % ownKeyLen;
      }
    }
    return table;
  }

  static Uint16List _buildMendIndex() {
    final table = Uint16List(phasePeriod * blockSize);
    for (var phase = 0; phase < phasePeriod; phase++) {
      for (var col = 0; col < blockSize; col++) {
        table[phase * blockSize + col] = (phase * blockSize + col) % mendTableLen;
      }
    }
    return table;
  }

  static int _scramble(int value) => (value ^ ((value & 0x0f) << 4)) & 0xff;

  static bool _matchesMagic(Uint8List head) =>
      _equalsAt(head, kgmMagic, 0) || _equalsAt(head, vprMagic, 0);

  static bool _equalsAt(Uint8List data, List<int> pattern, int offset) {
    if (data.length < offset + pattern.length) return false;
    for (var i = 0; i < pattern.length; i++) {
      if (data[offset + i] != pattern[i]) return false;
    }
    return true;
  }

  /// 解密后按首字节猜输出格式（与 kgm.js 的 sniff 逻辑一致）。
  ///
  /// 返回 `'flac' | 'mp3' | 'ogg' | 'm4a' | 'wav'`，认不出返回 `null`。
  static String? _sniffFormat(Uint8List data) {
    if (data.length < 12) return null;
    if (_equalsAt(data, const <int>[0x66, 0x4C, 0x61, 0x43], 0)) return 'flac'; // fLaC
    if (_equalsAt(data, const <int>[0x4F, 0x67, 0x67, 0x53], 0)) return 'ogg'; // OggS
    if (_equalsAt(data, const <int>[0x66, 0x74, 0x79, 0x70], 4)) return 'm4a'; // ftyp @4
    if (_equalsAt(data, const <int>[0x49, 0x44, 0x33], 0)) return 'mp3'; // ID3
    if (data[0] == 0xFF && (data[1] & 0xE0) == 0xE0) return 'mp3'; // MPEG 帧同步
    if (_equalsAt(data, const <int>[0x52, 0x49, 0x46, 0x46], 0) &&
        _equalsAt(data, const <int>[0x57, 0x41, 0x56, 0x45], 8)) {
      return 'wav'; // RIFF....WAVE
    }
    return null;
  }
}
