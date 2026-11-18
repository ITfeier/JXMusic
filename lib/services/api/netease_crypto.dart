import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 网易云 weapi 加密（公开逆向算法）
class NeteaseCrypto {
  static const String _aesKey = '0CoJUm6Qyw8W8jud';
  static const String _iv = '0102030405060708';
  static const String _rsaModulus =
      '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7';
  static const String _rsaExponent = '010001';

  /// 生成随机 16 位字母数字 key（weapi 协议要求 secKey 恰为 16 字节，
  /// AES-128 才能在服务端正确解密；base64 的 24 字节是 AES-192，会被拒）
  static const String _keyChars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  static String _randomKey() {
    final rng = Random.secure();
    return String.fromCharCodes(List<int>.generate(
        16, (_) => _keyChars.codeUnitAt(rng.nextInt(_keyChars.length))));
  }

  /// AES-CBC 加密（PKCS7 填充）
  static String _aesEncrypt(String plainText, String key) {
    final keyBytes = Uint8List.fromList(utf8.encode(key));
    final ivBytes = Uint8List.fromList(utf8.encode(_iv));
    final data = Uint8List.fromList(utf8.encode(plainText));
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(keyBytes), ivBytes));
    final padded = _pkcs7Pad(data, 16);
    final out = Uint8List(padded.length);
    var offset = 0;
    while (offset < padded.length) {
      cipher.processBlock(padded, offset, out, offset);
      offset += 16;
    }
    return base64Encode(out);
  }

  static Uint8List _pkcs7Pad(Uint8List data, int blockSize) {
    final pad = blockSize - (data.length % blockSize);
    final out = Uint8List(data.length + pad);
    out.setRange(0, data.length, data);
    for (var i = data.length; i < out.length; i++) {
      out[i] = pad;
    }
    return out;
  }

  /// RSA 无填充加密（weapi 协议）：对**反转后**的 secretKey 做 m^e mod n，
  /// 结果左补零到固定 256 位十六进制（服务端按固定宽度解析 encSecKey）。
  /// 不再复用 pointycastle 的 RSAEngine：其输出在高位为零时可能不足 128 字节，
  /// 导致 encSecKey 少于 256 字符而被服务端拒绝。
  static String _rsaEncrypt(String text) {
    final modulus = BigInt.parse(_rsaModulus, radix: 16);
    final exponent = BigInt.parse(_rsaExponent, radix: 16);
    final reversed = String.fromCharCodes(text.codeUnits.reversed);
    var m = BigInt.zero;
    for (final byte in utf8.encode(reversed)) {
      m = (m << 8) | BigInt.from(byte);
    }
    final encrypted = m.modPow(exponent, modulus);
    return encrypted.toRadixString(16).padLeft(256, '0');
  }

  /// weapi 加密入口
  static Map<String, String> weapi(Map<String, dynamic> data) {
    final plain = jsonEncode(data);
    final secKey = _randomKey();
    final params = _aesEncrypt(_aesEncrypt(plain, _aesKey), secKey);
    final encSecKey = _rsaEncrypt(secKey);
    return {'params': params, 'encSecKey': encSecKey};
  }

  /// eapi 客户端协议密钥（NeteaseCloudMusicApi util/crypto.js eapiKey）
  static const String _eapiKey = 'e82ckenh8dichen8';

  /// eapi 加密（客户端协议，登录等风控敏感接口使用）：
  /// 明文 `url-36cd479b6b5-{json}-36cd479b6b5-{md5(nobody url use text md5forencrypt)}`，
  /// AES-128-ECB(key=eapiKey) + PKCS7，输出大写 hex。
  /// 无随机成分，同一输入输出确定（可用参考向量锁定算法）。
  static String eapi(String url, Map<String, dynamic> data) {
    final text = jsonEncode(data);
    final digest = md5
        .convert(utf8.encode('nobody${url}use${text}md5forencrypt'))
        .toString();
    final payload = '$url-36cd479b6b5-$text-36cd479b6b5-$digest';
    final cipher = ECBBlockCipher(AESEngine())
      ..init(true, KeyParameter(Uint8List.fromList(utf8.encode(_eapiKey))));
    final plain = Uint8List.fromList(utf8.encode(payload));
    final pad = 16 - (plain.length % 16);
    final padded = Uint8List(plain.length + pad)
      ..setRange(0, plain.length, plain);
    for (var i = plain.length; i < padded.length; i++) {
      padded[i] = pad;
    }
    final out = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += 16) {
      cipher.processBlock(padded, offset, out, offset);
    }
    return out
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
  }
}
