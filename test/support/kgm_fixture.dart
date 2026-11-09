import 'dart:math' as math;
import 'dart:typed_data';

/// 合成酷狗 KGM / KGMA / VPR 加密样本的测试夹具（纯 Dart，不依赖 Flutter）。
///
/// 加密侧是 `KgmDecoder` 解密公式的严格逆运算：
/// ```
/// 密文 = scramble(明文 ^ scramble(pubValue ^ MEND[pubIdx])) ^ ownKey[ownIdx]
/// ```
/// 由于 `scramble(v) = v ^ ((v & 0x0F) << 4)` 是自逆变换（做两次还原），
/// 把上述结果再按解密公式处理即可还原明文，因此可用于回环测试。
///
/// 常量（magic、MEND 表）独立抄自 MIT 参考实现
/// `_ref/dsh-audio-converter/lib/crypto/kgm.js`，用于交叉验证解码器常量。
class KgmFixture {
  KgmFixture._();

  /// 文件头固定 1024 字节。
  static const int headerLen = 1024;

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

  /// 测试用默认私钥主体（16 字节，解码器会补一个 0x00）。
  static const List<int> defaultOwnKey16 = <int>[
    0x6b, 0x75, 0x67, 0x6f, 0x75, 0x2d, 0x6b, 0x67, // "kugou-kg"
    0x6d, 0x2d, 0x74, 0x65, 0x73, 0x74, 0x21, 0x21, // "m-test!!"
  ];

  /// 公开的 MEND 表（272 字节，独立抄自参考实现 kgm.js）。
  static const List<int> mendTable = <int>[
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
  ];

  /// WAV 文件头前缀（RIFF....WAVE，12 字节），用于格式嗅探测试。
  static const List<int> wavHeaderPrefix = <int>[
    0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
    0x57, 0x41, 0x56, 0x45,
  ];

  /// 生成 WAV PCM 单声道 16-bit 正弦波 payload（默认 8 kHz / 120 ms ≈ 1.9 KB）。
  static Uint8List buildWavPcm({
    int sampleRate = 8000,
    int durationMs = 120,
    double frequency = 440.0,
  }) {
    final sampleCount = sampleRate * durationMs ~/ 1000;
    final dataLen = sampleCount * 2;
    final bytes = Uint8List(44 + dataLen);
    final view = ByteData.sublistView(bytes);

    bytes.setAll(0, 'RIFF'.codeUnits);
    view.setUint32(4, 36 + dataLen, Endian.little); // 文件长度 - 8
    bytes.setAll(8, 'WAVE'.codeUnits);
    bytes.setAll(12, 'fmt '.codeUnits);
    view.setUint32(16, 16, Endian.little); // fmt 块长度
    view.setUint16(20, 1, Endian.little); // PCM
    view.setUint16(22, 1, Endian.little); // 单声道
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, sampleRate * 2, Endian.little); // 每秒字节数
    view.setUint16(32, 2, Endian.little); // 块对齐
    view.setUint16(34, 16, Endian.little); // 位深
    bytes.setAll(36, 'data'.codeUnits);
    view.setUint32(40, dataLen, Endian.little);
    for (var i = 0; i < sampleCount; i++) {
      final sample =
          (math.sin(2 * math.pi * frequency * i / sampleRate) * 0.5 * 0x7FFF).round();
      view.setInt16(44 + i * 2, sample, Endian.little);
    }
    return bytes;
  }

  /// 生成指定头部魔数、确定性伪随机内容的 payload（长度至少 12 字节）。
  static Uint8List payloadWithMagic({
    List<int> prefix = const <int>[],
    int prefixOffset = 0,
    int length = 64,
    int seed = 1,
  }) {
    final bytes = Uint8List(length);
    var state = (seed * 2654435761 + 1013904223) & 0xFFFFFFFF;
    for (var i = 0; i < length; i++) {
      state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
      bytes[i] = (state >> 16) & 0xff;
    }
    bytes.setAll(prefixOffset, prefix);
    return bytes;
  }

  /// 计算加密后的音频字节（解密公式的逆运算）。
  static Uint8List encryptPayload(
    Uint8List plain, {
    required Uint8List pubKey,
    List<int> ownKey16 = defaultOwnKey16,
  }) {
    if (ownKey16.length != 16) {
      throw ArgumentError.value(ownKey16.length, 'ownKey16', '必须为 16 字节');
    }
    final blockCount = (plain.length + 15) ~/ 16;
    if (blockCount > pubKey.length) {
      throw ArgumentError.value(
        pubKey.length,
        'pubKey',
        '公钥表不足：需要 $blockCount 字节',
      );
    }
    final ownKey = Uint8List(17)..setAll(0, ownKey16); // 第 17 字节保持 0x00
    final out = Uint8List(plain.length);
    for (var offset = 0; offset < plain.length; offset++) {
      final blockIdx = offset ~/ 16;
      final col = offset % 16;
      final idx = (blockIdx % 17) * 16 + col;
      final own = ownKey[idx % 17];
      final mask = _scramble(pubKey[blockIdx] ^ mendTable[idx % mendTable.length]);
      out[offset] = _scramble(plain[offset] ^ mask) ^ own;
    }
    return out;
  }

  /// 构造一个完整的 KGM / VPR 文件。
  ///
  /// - [audioOffset] 写入文件头声明的音频偏移（默认 1024）；音频数据物理上
  ///   始终紧跟 1024 字节头，便于构造「非法偏移」异常样本。
  /// - [cryptoVersion] 写入加密版本（5 = KGG，用于验证拒绝逻辑）。
  /// - [encrypt] 为 false 时直接以明文 payload 填充音频区（仅用于魔数测试）。
  static Uint8List buildFile({
    required Uint8List payload,
    required Uint8List pubKey,
    List<int> magic = kgmMagic,
    List<int> ownKey16 = defaultOwnKey16,
    int cryptoVersion = 3,
    int audioOffset = 1024,
    bool encrypt = true,
  }) {
    final audio = encrypt
        ? encryptPayload(payload, pubKey: pubKey, ownKey16: ownKey16)
        : Uint8List.fromList(payload);
    final file = Uint8List(headerLen + audio.length);
    final header = ByteData.sublistView(file, 0, headerLen);

    file.setAll(0, magic);
    header.setUint32(0x10, audioOffset, Endian.little);
    header.setUint32(0x14, cryptoVersion, Endian.little);
    header.setUint32(0x18, 1, Endian.little); // 参考实现中固定的标记值
    file.setAll(0x1c, ownKey16);
    file.setAll(headerLen, audio);
    return file;
  }

  static int _scramble(int value) => (value ^ ((value & 0x0f) << 4)) & 0xff;
}
