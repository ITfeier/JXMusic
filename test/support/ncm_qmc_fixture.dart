// NCM / QMC 加密样本构造器（纯 Dart，仅测试用）。
//
// 目的：不依赖任何真实版权样本，也能端到端验证「加密 → 解密」链路。
// **本文件独立实现加密侧**，不调用 vendored 包（被测解密实现）的任何函数：
// - NCM：按 ncmdump 文件结构生成（AES-128-ECB 音频密钥 + 元数据块 +
//   RC4 变体密钥流音频段），AES 用 pointycastle 的加密方向；
// - QMC v1：静态密钥（256 字节公开常量）二次索引异或；
// - QMC v2：尾部 EKey（腾讯 TEA-CBC 加密侧）+ Map / 分段 RC4 流密码。
//
// 格式依据：`packages/music_decoder`（vendored MIT，未修改）与
// `_ref/music_decoder`、`_ref/dsh-audio-converter/lib/crypto`（MIT）的算法说明。
// 跨语言黄金向量由独立实现生成，见 test/local_formats/ncm_qmc_test.dart。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// ---------------------------------------------------------------------------
// 通用工具
// ---------------------------------------------------------------------------

Uint8List uint32Le(int value) {
  return Uint8List.fromList([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);
}

Uint8List uint32Be(int value) {
  return Uint8List.fromList([
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);
}

int readUint32Le(Uint8List bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

int readUint32Be(Uint8List bytes, int offset) {
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

bool bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

Uint8List hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s+'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List xorByte(Uint8List data, int value) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = data[i] ^ value;
  }
  return out;
}

Uint8List pkcs7Pad(Uint8List data) {
  final padding = 16 - data.length % 16;
  final out = Uint8List(data.length + padding);
  out.setRange(0, data.length, data);
  out.fillRange(data.length, out.length, padding);
  return out;
}

Uint8List aesEcbEncrypt(Uint8List key, Uint8List data) {
  final cipher = ECBBlockCipher(AESEngine());
  cipher.init(true, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var offset = 0; offset < data.length; offset += cipher.blockSize) {
    cipher.processBlock(data, offset, out, offset);
  }
  return out;
}

// ---------------------------------------------------------------------------
// WAV PCM 负载（16-bit 单声道正弦波）
// ---------------------------------------------------------------------------

/// 生成 16-bit 单声道正弦波 WAV（默认 8kHz / 1.5s ≈ 24KB，覆盖多个解密分块）。
Uint8List buildWavPayload({
  int sampleRate = 8000,
  int milliseconds = 1500,
  double frequency = 440,
}) {
  final sampleCount = sampleRate * milliseconds ~/ 1000;
  final pcm = ByteData(sampleCount * 2);
  for (var i = 0; i < sampleCount; i++) {
    final sample = (sin(2 * pi * frequency * i / sampleRate) * 0.4 * 32767)
        .round();
    pcm.setInt16(i * 2, sample, Endian.little);
  }
  // 固定让最后两个采样点取最大值：保证文件末尾 4 字节是大的正整数，
  // 不会被 QMC v1/v2 尾包启发式误判成「小端密钥长度」。
  pcm.setInt16((sampleCount - 2) * 2, 0x7FFF, Endian.little);
  pcm.setInt16((sampleCount - 1) * 2, 0x7FFF, Endian.little);

  final pcmBytes = pcm.buffer.asUint8List();
  final header = ByteData(44);
  _writeAscii(header, 0, 'RIFF');
  header.setUint32(4, 36 + pcmBytes.length, Endian.little);
  _writeAscii(header, 8, 'WAVE');
  _writeAscii(header, 12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // 单声道
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  _writeAscii(header, 36, 'data');
  header.setUint32(40, pcmBytes.length, Endian.little);

  final out = Uint8List(44 + pcmBytes.length);
  out.setRange(0, 44, header.buffer.asUint8List());
  out.setRange(44, out.length, pcmBytes);
  return out;
}

void _writeAscii(ByteData data, int offset, String text) {
  for (var i = 0; i < text.length; i++) {
    data.setUint8(offset + i, text.codeUnitAt(i));
  }
}

// ---------------------------------------------------------------------------
// NCM 合成样本
// ---------------------------------------------------------------------------

/// 最小「PNG」封面（签名 + 标记字节；测试只做字节比对/标签写入）。
Uint8List buildFakePngCover() {
  final builder = BytesBuilder(copy: false)
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(utf8.encode('JXMusic-NCM-Cover'));
  return builder.takeBytes();
}

class NcmFixture {
  const NcmFixture({
    required this.bytes,
    required this.audioPayload,
    required this.metadata,
    required this.audioOffset,
    this.cover,
  });

  final Uint8List bytes;
  final Uint8List audioPayload;
  final Map<String, dynamic> metadata;

  /// 音频段起始偏移；`bytes.sublist(0, audioOffset)` 即「只含头部的文件」。
  final int audioOffset;
  final Uint8List? cover;
}

final Uint8List ncmCoreKey = hexToBytes('687A4852416D736F356B496E62617857');
final Uint8List ncmMetaKey = hexToBytes('2331346C6A6B5F215C5D2630553C2728');
const String _ncmMetaTextPrefix = "163 key(Don't modify):";
const String _ncmAudioKeyPrefix = 'neteasecloudmusic';

/// 按 ncmdump 结构生成 NCM 文件：
/// ```
/// magic(8) | 0x01 0x70 | keyLen LE(4) | keyData | metaLen LE(4) | metaData
/// | crc32(4) | unknown(5) | coverLen LE(4) | cover | audio(密钥流异或)
/// ```
NcmFixture buildNcmFixture({
  required Uint8List audioPayload,
  String format = 'wav',
  String title = '测试歌曲',
  String album = '测试专辑',
  List<String> artists = const ['测试歌手'],
  Uint8List? cover,
  Uint8List? audioKey,
}) {
  final resolvedCover = cover ?? buildFakePngCover();
  final resolvedAudioKey = audioKey ?? _defaultNcmAudioKey();
  final metadata = <String, dynamic>{
    'format': format,
    'musicName': title,
    'album': album,
    'artist': [
      for (var i = 0; i < artists.length; i++) [artists[i], i + 1],
    ],
    'bitrate': 320000,
    'duration': 1500,
  };

  final keyPlain = Uint8List.fromList([
    ...utf8.encode(_ncmAudioKeyPrefix),
    ...resolvedAudioKey,
  ]);
  final keyCipher = xorByte(
    aesEcbEncrypt(ncmCoreKey, pkcs7Pad(keyPlain)),
    0x64,
  );

  final metaPlain = utf8.encode('music:${jsonEncode(metadata)}');
  final metaAes = aesEcbEncrypt(ncmMetaKey, pkcs7Pad(metaPlain));
  // 真实格式：`"163 key(Don't modify):" + base64(AES 密文)` 整体再逐字节 XOR 0x63。
  final metaBlock = Uint8List.fromList([
    ...utf8.encode(_ncmMetaTextPrefix),
    ...base64.encode(metaAes).codeUnits,
  ]);
  final metaCipherText = xorByte(metaBlock, 0x63);

  final keystream = _ncmKeyStream(resolvedAudioKey);
  final audioCipher = Uint8List(audioPayload.length);
  for (var i = 0; i < audioPayload.length; i++) {
    audioCipher[i] = audioPayload[i] ^ keystream[i % keystream.length];
  }

  final builder = BytesBuilder(copy: false)
    ..add(utf8.encode('CTENFDAM'))
    ..add([0x01, 0x70])
    ..add(uint32Le(keyCipher.length))
    ..add(keyCipher)
    ..add(uint32Le(metaCipherText.length))
    ..add(metaCipherText)
    ..add(uint32Le(0)) // 封面 CRC32（解密实现不校验）
    ..add(Uint8List(5)) // 5 字节未知字段
    ..add(uint32Le(resolvedCover.length))
    ..add(resolvedCover)
    ..add(audioCipher);
  final bytes = builder.takeBytes();

  return NcmFixture(
    bytes: bytes,
    audioPayload: audioPayload,
    metadata: metadata,
    audioOffset: bytes.length - audioPayload.length,
    cover: resolvedCover,
  );
}

Uint8List _defaultNcmAudioKey() {
  return Uint8List.fromList(
    List<int>.generate(32, (i) => (i * 37 + 11) & 0xFF),
  );
}

/// `packages/music_decoder` 内 `_generateKeyStream` 对应算法的独立实现：
/// 256 字节密钥流，按 256 循环，音频第 i 字节与 `stream[(i + 1) % 256]` 异或。
Uint8List _ncmKeyStream(Uint8List audioKey) {
  final box = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + box[i] + audioKey[i % audioKey.length]) & 0xFF;
    final temp = box[i];
    box[i] = box[j];
    box[j] = temp;
  }
  final stream = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    final index = (box[i] + box[(i + box[i]) & 0xFF]) & 0xFF;
    stream[i] = box[index];
  }
  final rotated = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    rotated[i] = stream[(i + 1) % 256];
  }
  return rotated;
}

// ---------------------------------------------------------------------------
// QMC v1：静态密钥（256 字节公开常量，二次索引异或）
// ---------------------------------------------------------------------------

/// 与包内 `qmc_constants.dart` 相同的公开静态密钥（测试侧独立副本，便于独立加密）。
final Uint8List qmcPrivateKey256 = hexToBytes(
  '77483273def2c0c895ec30b251c3e1a0'
  '9ee69dcffa7f14d1ceb8dcc34a6793d6'
  '28c29170ca8da2a4f00861907e6fa2e0'
  'ebae3eb667c792f491b5f66c5e8440f7'
  'f31b027fd5ab418928f425cc5211ad43'
  '68a6418b84b5ff2c924a26d8476a7c95'
  '61cce6cbbb3f4758'
  '8975c375a1d9afcc087317dcaa9aa216'
  '41d8a206c68bfc66349fcf1823a00a74'
  'e72b277092e9af37e68ca7bc62659cc2'
  '08c988b3f343ac742c0fd4afa1c30164'
  '954e489ff43578957a39d66aa06d40e8'
  '4fa8ef111df31b3f3f07dd6f5b193019'
  'fbef0e37f00ecd1649fe5347131abda4'
  'f14019600eed6809065f4dcf3d1afe20'
  '77e4d9daf9a42b761c71db00bcfd0c6c'
  'a547f7f600794a11',
);

/// QMC v1（qmc0/qmc2/qmc3/tkm/bkc*/hex 扩展名）：文件 = 密文，无尾部。
/// 异或变换自逆，因此同一函数既是加密也是解密。
Uint8List buildQmcV1Fixture(Uint8List audioPayload) {
  final out = Uint8List(audioPayload.length);
  for (var i = 0; i < audioPayload.length; i++) {
    out[i] = audioPayload[i] ^ _qmcStaticMask(i);
  }
  return out;
}

int _qmcStaticMask(int offset) {
  final temp = offset > 0x7FFF ? offset % 0x7FFF : offset;
  final index = (temp * temp + 27) & 0xFF;
  return qmcPrivateKey256[index];
}

// ---------------------------------------------------------------------------
// QMC v2：尾部 EKey（TEA-CBC 加密侧）+ Map / RC4 流密码
// ---------------------------------------------------------------------------

enum QmcKeyTailStyle {
  /// PC 端老格式：`audio | base64(EKey) | keySize(LE4)`。
  pcLegacy,

  /// 安卓端 QTag 格式：`audio | base64(EKey),2 | keySize(BE4) | "QTag"`。
  qTag,
}

class QmcV2Fixture {
  const QmcV2Fixture({
    required this.bytes,
    required this.masterKey,
    required this.eKey,
  });

  final Uint8List bytes;
  final Uint8List masterKey;
  final String eKey;
}

/// 构造 QMC v2 样本。
///
/// [masterKey] 长度须为 8 的倍数且 ≥16：长度 ≤300 走 Map 流密码，
/// >300 走分段 RC4 流密码（与包内 `_buildCipher` 的选择一致）。
QmcV2Fixture buildQmcV2Fixture({
  required Uint8List audioPayload,
  required Uint8List masterKey,
  QmcKeyTailStyle tailStyle = QmcKeyTailStyle.pcLegacy,
}) {
  _validateMasterKey(masterKey);
  if (masterKey.length <= 300 && masterKey.length < 256) {
    // 包内 QmMapCipher 的 mask 索引是 (offset² + 71214) & 0xFF，直接索引主密钥；
    // 主密钥不足 256 字节会越界，因此 Map 路径要求 ≥256 字节。
    throw ArgumentError.value(
      masterKey.length,
      'masterKey',
      'Map 流密码要求主密钥不少于 256 字节（包内按 0..255 索引）',
    );
  }
  final encryptedAudio = masterKey.length > 300
      ? _qmcRc4Transform(audioPayload, masterKey)
      : _qmcMapTransform(audioPayload, masterKey);
  final eKey = base64.encode(encodeQmcV2EKeyBytes(masterKey));

  final builder = BytesBuilder(copy: false)..add(encryptedAudio);
  if (tailStyle == QmcKeyTailStyle.qTag) {
    final keyBytes = utf8.encode('$eKey,2');
    builder
      ..add(keyBytes)
      ..add(uint32Be(keyBytes.length))
      ..add(utf8.encode('QTag'));
  } else {
    final keyBytes = utf8.encode(eKey);
    builder
      ..add(keyBytes)
      ..add(uint32Le(keyBytes.length));
  }

  return QmcV2Fixture(
    bytes: builder.takeBytes(),
    masterKey: masterKey,
    eKey: eKey,
  );
}

/// 生成 QMC v2 尾部 EKey 的原始字节（未 base64）：
/// `masterKey[0..8) | TEA-CBC(masterKey[8..])`，与包内 `QmcKeyDecoder.deriveKey` 互逆。
Uint8List encodeQmcV2EKeyBytes(Uint8List masterKey) {
  _validateMasterKey(masterKey);
  final header = Uint8List.fromList(masterKey.sublist(0, 8));
  final teaKey = _buildTeaKey(header);
  final body = masterKey.sublist(8);

  // 解密侧结构：1 字节 padLength + 6 字节填充 + 2 字节 salt + 正文 + 7 个零。
  // pad 低 3 位必须为 6（解密侧要求 paddingLength + 2 == 8），其余填充不校验。
  final plain = Uint8List(body.length + 16);
  plain[0] = 0x06;
  plain.fillRange(1, 7, 0x06);
  plain.setRange(9, 9 + body.length, body);

  final encrypted = _tencentTeaCbcEncrypt(plain, teaKey);
  final out = Uint8List(8 + encrypted.length);
  out.setRange(0, 8, header);
  out.setRange(8, out.length, encrypted);
  return out;
}

/// 构造「尾部密钥长度合法、内容不是 base64」的损坏样本，用于失败路径用例。
Uint8List buildQmcCorruptKeyFixture({required Uint8List audioPayload}) {
  final keyBytes = Uint8List(0x40); // 0x40 >= 16 且 < 0x300，会被当成 v2 尾包
  final builder = BytesBuilder(copy: false)
    ..add(audioPayload)
    ..add(keyBytes)
    ..add(uint32Le(keyBytes.length));
  return builder.takeBytes();
}

/// 构造 musicex 新版尾部样本（无内嵌 EKey，只有尾部魔数）。
Uint8List buildQmcMusicExTailFixture({required Uint8List audioPayload}) {
  final builder = BytesBuilder(copy: false)
    ..add(audioPayload)
    ..add(utf8.encode('musicex'))
    ..addByte(0);
  return builder.takeBytes();
}

/// 构造 STag 尾部样本（只有资源元数据、没有 EKey）。
Uint8List buildQmcSTagFixture({required Uint8List audioPayload}) {
  final csv = utf8.encode('67890,2,0011wjLv1bIkvv');
  final builder = BytesBuilder(copy: false)
    ..add(audioPayload)
    ..add(csv)
    ..add(uint32Be(csv.length))
    ..add(utf8.encode('STag'));
  return builder.takeBytes();
}

/// 生成确定性的 v2 主密钥（[length] 为 8 的倍数）。
Uint8List buildQmcMasterKey(int length) {
  final out = Uint8List.fromList(
    List<int>.generate(length, (i) => (i * 53 + 7) & 0xFF),
  );
  _validateMasterKey(out);
  return out;
}

void _validateMasterKey(Uint8List masterKey) {
  if (masterKey.length < 16 || masterKey.length % 8 != 0) {
    throw ArgumentError.value(
      masterKey.length,
      'masterKey',
      'QMC v2 主密钥长度必须是 8 的倍数且不少于 16 字节',
    );
  }
}

// --- Map 流密码（≤300 字节主密钥）----------------------------------------

Uint8List _qmcMapTransform(Uint8List data, Uint8List key) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = data[i] ^ _qmcMapMask(key, i);
  }
  return out;
}

int _qmcMapMask(Uint8List key, int offset) {
  final temp = offset > 0x7FFF ? offset % 0x7FFF : offset;
  final index = (temp * temp + 71214) & 0xFF;
  return _rotateByte(key[index], index & 0x7);
}

int _rotateByte(int value, int bits) {
  final rotate = (bits + 4) % 8;
  final left = (value << rotate) & 0xFF;
  final right = value >> rotate;
  return (left | right) & 0xFF;
}

// --- 分段 RC4 流密码（>300 字节主密钥）-----------------------------------

Uint8List _qmcRc4Transform(Uint8List data, Uint8List key) {
  final cipher = _QmcRc4FixtureCipher(key);
  return cipher.transform(data);
}

/// 与包内 `QmRc4Cipher` 等价的分段 RC4 密钥流（异或，自逆）。
class _QmcRc4FixtureCipher {
  _QmcRc4FixtureCipher(this.originKey)
    : originKeyLength = originKey.length,
      seedBox = Uint8List(originKey.length) {
    for (var i = 0; i < originKeyLength; i++) {
      seedBox[i] = i & 0xFF;
    }
    var tempIndex = 0;
    for (var i = 0; i < originKeyLength; i++) {
      tempIndex =
          (seedBox[i] + tempIndex + originKey[i % originKeyLength]) %
          originKeyLength;
      final temp = seedBox[i];
      seedBox[i] = seedBox[tempIndex];
      seedBox[tempIndex] = temp;
    }

    var hash = 1;
    for (var i = 0; i < originKeyLength; i++) {
      final value = originKey[i];
      if (value == 0) {
        continue;
      }
      final nextHash = (hash * value) & 0xFFFFFFFF;
      if (nextHash == 0 || nextHash <= hash) {
        break;
      }
      hash = nextHash;
    }
    hashValue = hash;
  }

  static const int firstSegmentSize = 0x80;
  static const int segmentSize = 0x1400;

  final Uint8List originKey;
  final int originKeyLength;
  final Uint8List seedBox;
  late final int hashValue;

  Uint8List transform(Uint8List data) {
    final result = Uint8List.fromList(data);
    var toProcess = result.length;
    var processed = 0;
    var offset = 0;

    bool postProcessed(int length) {
      toProcess -= length;
      processed += length;
      offset += length;
      return toProcess == 0;
    }

    if (offset < firstSegmentSize) {
      final length = min(result.length, firstSegmentSize - offset);
      _transformFirstSegment(result, processed, length, offset);
      if (postProcessed(length)) {
        return result;
      }
    }
    if (offset % segmentSize != 0) {
      final length = min(segmentSize - (offset % segmentSize), toProcess);
      _transformAllSegment(result, processed, length, offset);
      if (postProcessed(length)) {
        return result;
      }
    }
    while (toProcess > segmentSize) {
      _transformAllSegment(result, processed, segmentSize, offset);
      postProcessed(segmentSize);
    }
    if (toProcess > 0) {
      _transformAllSegment(result, processed, toProcess, offset);
    }
    return result;
  }

  void _transformFirstSegment(
    Uint8List buffer,
    int start,
    int length,
    int offset,
  ) {
    for (var i = 0; i < length; i++) {
      buffer[start + i] ^= originKey[_segmentKey(offset + i)];
    }
  }

  void _transformAllSegment(
    Uint8List buffer,
    int start,
    int length,
    int offset,
  ) {
    final newSeedBox = Uint8List.fromList(seedBox);
    final skipLength =
        (offset % segmentSize) + _segmentKey(offset ~/ segmentSize);

    var left = 0;
    var right = 0;
    for (var index = -skipLength; index < length; index++) {
      left = (left + 1) % originKeyLength;
      right = (newSeedBox[left] + right) % originKeyLength;
      final temp = newSeedBox[right];
      newSeedBox[right] = newSeedBox[left];
      newSeedBox[left] = temp;

      if (index >= 0) {
        final seedValue = newSeedBox[left] + newSeedBox[right];
        buffer[start + index] ^= newSeedBox[seedValue % originKeyLength];
      }
    }
  }

  int _segmentKey(int index) {
    final seed = originKey[index % originKeyLength];
    if (seed == 0) {
      return 0;
    }
    final value = (hashValue / ((index + 1) * seed)) * 100;
    return value.floor() % originKeyLength;
  }
}

// --- 腾讯 TEA-CBC 加密侧 --------------------------------------------------

/// 包内 `_simpleMakeKey(seed: 106, length: 8)` 的等价实现。
Uint8List _qmcSimpleKey() {
  final out = Uint8List(8);
  for (var i = 0; i < 8; i++) {
    final value = tan(106 + i * 0.1).abs() * 100;
    out[i] = value.floor() & 0xFF;
  }
  return out;
}

Uint8List _buildTeaKey(Uint8List header) {
  final simpleKey = _qmcSimpleKey();
  final teaKey = Uint8List(16);
  for (var i = 0; i < 8; i++) {
    teaKey[i << 1] = simpleKey[i];
    teaKey[(i << 1) + 1] = header[i];
  }
  return teaKey;
}

/// 腾讯 TEA-CBC 链式（包内解密公式的逆）。
///
/// 包内解密：`T0 = D(C0)`；`Tk = D(T(k-1) ^ Ck)`；`Pk = Tk ^ C(k-1)`。
/// 因此加密：`T0 = P0`；`Tk = Pk ^ C(k-1)`；`Ck = E(Tk) ^ T(k-1)`。
Uint8List _tencentTeaCbcEncrypt(Uint8List plain, Uint8List teaKey) {
  final blockCount = plain.length ~/ 8;
  final out = Uint8List(plain.length);
  final previousT = Uint8List(8);
  final currentT = Uint8List(8);
  for (var block = 0; block < blockCount; block++) {
    final base = block * 8;
    for (var i = 0; i < 8; i++) {
      final previousCipher = block == 0 ? 0 : out[base - 8 + i];
      currentT[i] = plain[base + i] ^ previousCipher;
    }
    final encrypted = _teaEncryptBlock(currentT, teaKey);
    for (var i = 0; i < 8; i++) {
      out[base + i] = encrypted[i] ^ previousT[i];
    }
    previousT.setRange(0, 8, currentT);
  }
  return out;
}

/// 包内 `_TeaCipher.decryptBlock`（rounds: 32 => 16 次迭代）的逆过程。
Uint8List _teaEncryptBlock(Uint8List block, Uint8List teaKey) {
  var v0 = readUint32Be(block, 0);
  var v1 = readUint32Be(block, 4);
  final key0 = readUint32Be(teaKey, 0);
  final key1 = readUint32Be(teaKey, 4);
  final key2 = readUint32Be(teaKey, 8);
  final key3 = readUint32Be(teaKey, 12);

  // 解密迭代 i 用 sum = delta * (16 - i)；加密需从 i=15 倒推回 0，故 sum 从 delta 递增。
  var sum = 0x9E3779B9;
  for (var i = 0; i < 16; i++) {
    v0 = (v0 + _teaMix(v1, sum, key0, key1)) & 0xFFFFFFFF;
    v1 = (v1 + _teaMix(v0, sum, key2, key3)) & 0xFFFFFFFF;
    sum = (sum + 0x9E3779B9) & 0xFFFFFFFF;
  }

  final out = Uint8List(8);
  _writeUint32Be(out, 0, v0);
  _writeUint32Be(out, 4, v1);
  return out;
}

int _teaMix(int value, int sum, int keyA, int keyB) {
  final left = ((value << 4) + keyA) & 0xFFFFFFFF;
  final right = ((value >> 5) + keyB) & 0xFFFFFFFF;
  final middle = (sum + value) & 0xFFFFFFFF;
  return (left ^ middle ^ right) & 0xFFFFFFFF;
}

void _writeUint32Be(Uint8List data, int offset, int value) {
  data[offset] = (value >> 24) & 0xFF;
  data[offset + 1] = (value >> 16) & 0xFF;
  data[offset + 2] = (value >> 8) & 0xFF;
  data[offset + 3] = value & 0xFF;
}
