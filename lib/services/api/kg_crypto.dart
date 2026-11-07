import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 酷狗 Web 登录态交换（`login_by_token_get`）所用的 AES / RSA 工具。
///
/// 协议来源：
/// - 官网登录 JS `kguser.v2.min.js` 的 `KgUser.QRCodeLogin`（`AES.encrypt` / `RSA.encrypt`）
/// - 公开仓库 `makcre/KuGouMusicApi` 的 `util/crypto.js`、`module/login_token.js`
///
/// 社区实现里存在两套并存的 AES 密钥派生约定，故这里把参数显式化：
/// - [md5KeyIv]：AESKey = `md5(随机key)` 前 32 位 hex（作为 32 字符 ASCII 密钥，AES-256），
///   IV = AESKey 后 16 位（makcre / Android 协议约定）。
/// - [webKeyIv]：官网 Web JS 直接以 16 位随机 key 同时作为 AESKey 与 IV（AES-128）。
///
/// RSA 均为 textbook（raw）加密：明文零左填充到密钥长度后 `modPow`，输出小写 hex。
class KgCrypto {
  /// 公开约定的 RSA 公钥（PKCS#8 SubjectPublicKeyInfo，1024 bit）。
  static const String publicKeyPem = '-----BEGIN PUBLIC KEY-----\n'
      'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/gbjDJ'
      'X51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1+UR4tvOGO'
      'qp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJE5E221wf/4WLF'
      'xwAtRQIDAQAB\n'
      '-----END PUBLIC KEY-----';

  /// 官网 `kguser.v2.min.js` 里 `RSA.encrypt` 内置的 1024 bit 模数（Web 旧协议默认公钥）。
  static const String webPublicModulusHex =
      'B1B1EC76A1BBDBF0D18E8CD9A87E53FA3881E2F004C67C9DDA2CA677DBEFA3D6'
      '1DF8463FE12D84FF4B4699E02C9D41CAB917F5A8FB9E35580C4BDF97763A0420'
      'A476295D763EE10174E6F9EBF7DF8A77BA5B20CDA4EE705DEF5BBA3C88567B96'
      '56E52C9CD5CD95CA735FF2D25F762B133273EEEB7B4F3EA8B6DA29040F3B67CD';

  static const int rsaExponent = 65537;

  /// 官网随机 key 字母表为 `0-9A-Z`，这里统一下小写字母 + 数字（16 位）。
  static const String _keyAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// 生成 16 位随机登录 key（pk 中回传给服务端，用于派生 AES 密钥）。
  static String randomKey16([Random? random]) {
    final rng = random ?? Random.secure();
    return List<String>.generate(
        16, (_) => _keyAlphabet[rng.nextInt(_keyAlphabet.length)]).join();
  }

  /// makcre / Android 约定：AESKey = md5(key) 前 32 位 hex，IV = AESKey 后 16 位。
  /// key 以 32 字符 ASCII 作为 AES-256 密钥。
  static ({String key, String iv}) md5KeyIv(String tempKey) {
    final aesKey = md5Hex(tempKey);
    return (key: aesKey, iv: aesKey.substring(aesKey.length - 16));
  }

  /// 官网 Web JS 约定：16 位随机 key 同时作为 AESKey 与 IV（AES-128）。
  static ({String key, String iv}) webKeyIv(String tempKey) =>
      (key: tempKey, iv: tempKey);

  /// AES-CBC / PKCS7 加密，返回小写 hex 密文。
  static String aesCbcEncryptHex(String plainText, String key, String iv) {
    final keyBytes = _keyBytes(key);
    final ivBytes = _ivBytes(iv);
    final data = Uint8List.fromList(utf8.encode(plainText));
    final padded = _pkcs7Pad(data, 16);
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(keyBytes), ivBytes));
    final out = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += 16) {
      cipher.processBlock(padded, offset, out, offset);
    }
    return toHex(out);
  }

  /// AES-CBC / PKCS7 解密（hex 密文），返回 UTF-8 明文。
  /// 密文非法/填充错误时抛 [FormatException]。
  static String aesCbcDecryptHex(String cipherHex, String key, String iv) {
    final keyBytes = _keyBytes(key);
    final ivBytes = _ivBytes(iv);
    final cipherBytes = fromHex(cipherHex);
    if (cipherBytes.isEmpty || cipherBytes.length % 16 != 0) {
      throw const FormatException('AES 密文长度非法');
    }
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(keyBytes), ivBytes));
    final out = Uint8List(cipherBytes.length);
    for (var offset = 0; offset < cipherBytes.length; offset += 16) {
      cipher.processBlock(cipherBytes, offset, out, offset);
    }
    final plain = _pkcs7Unpad(out);
    return utf8.decode(plain);
  }

  /// textbook RSA 加密：明文零左填充至模数长度后 `modPow(e, n)`，输出小写 hex。
  /// [modulusHex] 缺省时使用 [publicKeyPem] 解析出的模数。
  static String rsaRawEncryptHex(String plainText, {String? modulusHex}) {
    final modulus =
        BigInt.parse(modulusHex ?? pemPublicKeyModulusHex(), radix: 16);
    final keyLen = (modulus.bitLength + 7) ~/ 8;
    final bytes = utf8.encode(plainText);
    if (bytes.length > keyLen) {
      throw ArgumentError('RSA 明文长度 ${bytes.length} 超过密钥长度 $keyLen');
    }
    final padded = Uint8List(keyLen);
    padded.setRange(keyLen - bytes.length, keyLen, bytes);
    final message = _bytesToBigInt(padded);
    final encrypted = message.modPow(BigInt.from(rsaExponent), modulus);
    return encrypted
        .toRadixString(16)
        .padLeft(keyLen * 2, '0')
        .toLowerCase();
  }

  /// 从 PKCS#8 SubjectPublicKeyInfo（PEM）中解析 RSA 模数 hex。
  static String pemPublicKeyModulusHex([String pem = publicKeyPem]) {
    final body = pem
        .replaceAll(RegExp(r'-----(BEGIN|END) PUBLIC KEY-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    final der = base64Decode(body);
    // SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
    final outer = _readTlv(der, 0);
    if (outer.tag != 0x30) throw const FormatException('不是合法的 DER SEQUENCE');
    var offset = outer.start;
    final alg = _readTlv(der, offset);
    offset = alg.start + alg.length;
    final bitString = _readTlv(der, offset);
    if (bitString.tag != 0x03) {
      throw const FormatException('缺少 subjectPublicKey BIT STRING');
    }
    // BIT STRING 内容首字节为 unused bits，随后是 RSAPublicKey SEQUENCE
    final rsaPub = _readTlv(der, bitString.start + 1);
    if (rsaPub.tag != 0x30) throw const FormatException('缺少 RSAPublicKey');
    final modulus = _readTlv(der, rsaPub.start);
    if (modulus.tag != 0x02) throw const FormatException('缺少 modulus INTEGER');
    var bytes = der.sublist(modulus.start, modulus.start + modulus.length);
    if (bytes.isNotEmpty && bytes[0] == 0) bytes = bytes.sublist(1);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// md5 小写 hex
  static String md5Hex(String text) =>
      md5.convert(utf8.encode(text)).toString();

  static String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List fromHex(String hex) {
    if (hex.isEmpty || hex.length.isOdd) {
      throw const FormatException('hex 字符串长度非法');
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) throw const FormatException('非法的 hex 字符串');
      out[i] = byte;
    }
    return out;
  }

  // ---- 内部工具 ----

  static Uint8List _keyBytes(String key) {
    final bytes = Uint8List.fromList(utf8.encode(key));
    if (bytes.length != 16 && bytes.length != 24 && bytes.length != 32) {
      throw ArgumentError('AES 密钥长度必须为 16/24/32 字节，实际 ${bytes.length}');
    }
    return bytes;
  }

  static Uint8List _ivBytes(String iv) {
    final bytes = Uint8List.fromList(utf8.encode(iv));
    if (bytes.length != 16) {
      throw ArgumentError('AES IV 必须为 16 字节，实际 ${bytes.length}');
    }
    return bytes;
  }

  static Uint8List _pkcs7Pad(Uint8List data, int blockSize) {
    final pad = blockSize - (data.length % blockSize);
    final out = Uint8List(data.length + pad);
    out.setRange(0, data.length, data);
    out.fillRange(data.length, out.length, pad);
    return out;
  }

  static Uint8List _pkcs7Unpad(Uint8List data) {
    if (data.isEmpty) throw const FormatException('AES 明文为空');
    final pad = data[data.length - 1];
    if (pad < 1 || pad > 16 || pad > data.length) {
      throw const FormatException('PKCS7 填充非法');
    }
    for (var i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) throw const FormatException('PKCS7 填充非法');
    }
    return data.sublist(0, data.length - pad);
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static ({int tag, int length, int start}) _readTlv(Uint8List der, int index) {
    if (index + 2 > der.length) throw const FormatException('DER 数据不完整');
    final tag = der[index];
    var length = der[index + 1];
    var offset = index + 2;
    if (length & 0x80 != 0) {
      final count = length & 0x7F;
      if (count == 0 || offset + count > der.length) {
        throw const FormatException('DER 长度非法');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | der[offset++];
      }
    }
    if (offset + length > der.length) {
      throw const FormatException('DER 内容越界');
    }
    return (tag: tag, length: length, start: offset);
  }
}
