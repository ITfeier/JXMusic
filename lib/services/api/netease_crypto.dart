import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// 网易云 weapi 加密（公开逆向算法）
class NeteaseCrypto {
  static const String _aesKey = '0CoJUm6Qyw8W8jud';
  static const String _iv = '0102030405060708';
  static const String _rsaModulus =
      '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7';
  static const String _rsaExponent = '010001';

  /// 生成随机 16 字节 base64 key
  static String _randomKey() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64Encode(bytes);
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

  /// RSA 加密（长除法实现，对应 JSEncrypt 默认行为）
  static String _rsaEncrypt(String text) {
    final publicKey = RSAPublicKey(
      BigInt.parse(_rsaModulus, radix: 16),
      BigInt.parse(_rsaExponent, radix: 16),
    );
    final engine = RSAEngine()
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));

    // 按最大块长 128-11=117 分段
    final textBytes = utf8.encode(text);
    final out = BytesBuilder();
    for (var i = 0; i < textBytes.length; i += 117) {
      final end = min(i + 117, textBytes.length);
      final chunk = Uint8List.fromList(textBytes.sublist(i, end));
      final encrypted = engine.process(chunk);
      out.add(encrypted);
    }
    return out.toBytes()
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// weapi 加密入口
  static Map<String, String> weapi(Map<String, dynamic> data) {
    final plain = jsonEncode(data);
    final secKey = _randomKey();
    final params = _aesEncrypt(_aesEncrypt(plain, _aesKey), secKey);
    final encSecKey = _rsaEncrypt(secKey);
    return {'params': params, 'encSecKey': encSecKey};
  }
}
