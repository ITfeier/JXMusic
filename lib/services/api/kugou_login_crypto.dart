import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 酷狗 `/v9/login_by_pwd` 密码登录加密（KuGouMusicApi util/crypto.js 移植）。
///
/// 协议要点（2026-11 对照 KuGouMusicApi main 分支）：
/// · AES：tempKey 取 16 位（数字+小写字母）→ key = md5(tempKey) 的 32 个 hex
///   字符（32 字节 → AES-256），iv = 同一 md5 的后 16 个字符；AES-CBC + PKCS7，
///   输出小写 hex。响应 `data.secu_params` 用同一 tempKey 解密得到 token。
/// · RSA：1024 位公钥**无填充**模幂（textbook RSA），明文 UTF-8 字节直接
///   m^e mod n，结果左补零到 256 个 hex 字符（pk 字段需再 toUpperCase）。
/// · 请求签名（android）：md5(salt + 参数按 key 排序的 `k=v` 拼接 + 请求体
///   字符串 + salt)，salt = OIlwieks28dk2k092lksi2UIkp，小写 hex。
class KugouLoginCrypto {
  KugouLoginCrypto._();

  /// android 请求签名盐值（util/helper.js signatureAndroidParams）
  static const String androidSalt = 'OIlwieks28dk2k092lksi2UIkp';

  /// 标准版 android 客户端标识（util/config.json）
  static const String appid = '1005';
  static const String clientver = '20489';

  /// /v9/login_by_pwd 固定设备令牌（module/login.js 硬编码）
  static const String t1 =
      '562a6f12a6e803453647d16a08f5f0c2ff7eee692cba2ab74cc4c8ab47fc467561a7c6b586ce7dc46a63613b246737c03a1dc8f8d162d8ce1d2c71893d19f1d4b797685a4c6d3d81341cbde65e488c4829a9b4d42ef2df470eb102979fa5adcdd9b4eecfea8b909ff7599abeb49867640f10c3c70fc444effca9d15db44a9a6c907731e2bb0f22cd9b3536380169995693e5f0e2424e3378097d3813186e3fe96bbe7023808a0981b4e2b6135a76faac';
  static const String t2 =
      '31c4daf4cf480169ccea1cb7d4a209295865a9d2b788510301694db229b87807469ea0d41b4d4b9173c2151da7294aeebfc9738df154bbdf11a4e117bb5dff6a3af8ce5ce333e681c1f29a44038f27567d58992eb81283e080778ac77db1400fdf49b7cf7e26be2e5af4da7830cc3be4';
  static const String t3 = 'MCwwLDAsMCwwLDAsMCwwLDA=';

  /// RSA-1024 公钥模数/指数（util/crypto.js publicRasKey，hex）
  static const String _rsaModulus =
      'c8006ed03842d2628209bd314984ca5ed6cfe06e30c95f9d4704d9c49791d7a935ba950ecb0bc8ebf5f5994f0bac927a7eb151b3c1de343303fa539c83136eccfd7d7e511e2dbce18eaa9f784c9b50d443e75865979e0a5e216e46c684066a8d6b998580bbaa22d73f5790286bb14742e83244e44db6d707ffe162c5c7002d45';
  static const String _rsaExponent = '010001';

  /// RSA 密钥长度（1024 bit / 8 字节）
  static const int _rsaKeyLength = 128;

  static final BigInt _rsaN = BigInt.parse(_rsaModulus, radix: 16);
  static final BigInt _rsaE = BigInt.parse(_rsaExponent, radix: 16);

  /// tempKey 字符池：数字 + 小写字母（cryptoAesEncrypt 的 randomString(16).toLowerCase()）
  static const String _tempKeyChars = '1234567890abcdefghijklmnopqrstuvwxyz';

  /// 随机 16 位 tempKey（数字 + 小写字母）
  static String randomTempKey() {
    final rng = Random.secure();
    return String.fromCharCodes(List<int>.generate(
        16, (_) => _tempKeyChars.codeUnitAt(rng.nextInt(_tempKeyChars.length))));
  }

  /// AES key：md5(tempKey) 的 32 个 hex 字符（32 字节 → AES-256）
  static String aesKey(String tempKey) =>
      md5.convert(utf8.encode(tempKey)).toString().substring(0, 32);

  /// AES iv：md5(tempKey) 的后 16 个字符
  static String aesIv(String tempKey) => aesKey(tempKey).substring(16);

  /// AES-CBC(PKCS7) 加密，输出小写 hex（cryptoAesEncrypt 无 opt 版本）
  static String aesEncryptHex(String plainText, String tempKey) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV(
          KeyParameter(Uint8List.fromList(utf8.encode(aesKey(tempKey)))),
          Uint8List.fromList(utf8.encode(aesIv(tempKey))),
        ),
      );
    final data = Uint8List.fromList(utf8.encode(plainText));
    final pad = 16 - (data.length % 16);
    final padded = Uint8List(data.length + pad)..setRange(0, data.length, data);
    for (var i = data.length; i < padded.length; i++) {
      padded[i] = pad;
    }
    final out = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += 16) {
      cipher.processBlock(padded, offset, out, offset);
    }
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// AES-CBC(PKCS7) 解密（hex 输入，大小写均可）；格式非法抛 FormatException
  static String aesDecryptHex(String hexText, String tempKey) {
    if (hexText.length % 32 != 0) {
      throw const FormatException('AES ciphertext length invalid');
    }
    final encrypted = Uint8List(hexText.length ~/ 2);
    for (var i = 0; i < encrypted.length; i++) {
      encrypted[i] = int.parse(hexText.substring(i * 2, i * 2 + 2), radix: 16);
    }
    if (encrypted.isEmpty) throw const FormatException('AES ciphertext empty');
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        false,
        ParametersWithIV(
          KeyParameter(Uint8List.fromList(utf8.encode(aesKey(tempKey)))),
          Uint8List.fromList(utf8.encode(aesIv(tempKey))),
        ),
      );
    final out = Uint8List(encrypted.length);
    for (var offset = 0; offset < encrypted.length; offset += 16) {
      cipher.processBlock(encrypted, offset, out, offset);
    }
    final pad = out.last;
    if (pad < 1 || pad > 16) throw const FormatException('AES padding invalid');
    return utf8.decode(out.sublist(0, out.length - pad), allowMalformed: true);
  }

  /// RSA 无填充加密（cryptoRSAEncrypt）：明文**右补零到 128 字节**后按
  /// 大整数 m^e mod n，结果左补零到 256 个 hex 字符（小写；pk 字段需
  /// 调用方再 toUpperCase）。补零与上游 forge 路径完全一致——服务端按
  /// 固定 128 字节缓冲解密，缺补零会导致 pk 无法解出 tempKey。
  static String rsaEncryptHex(String plainText) {
    final bytes = utf8.encode(plainText);
    if (bytes.length > _rsaKeyLength) {
      throw ArgumentError('RSA plaintext exceeds key size');
    }
    final padded = Uint8List(_rsaKeyLength)..setRange(0, bytes.length, bytes);
    var m = BigInt.zero;
    for (final byte in padded) {
      m = (m << 8) | BigInt.from(byte);
    }
    return m
        .modPow(_rsaE, _rsaN)
        .toRadixString(16)
        .padLeft(_rsaKeyLength * 2, '0');
  }

  /// android 请求签名（signatureAndroidParams）：
  /// md5(salt + 参数按 key 排序的 `k=v` 直接拼接 + 请求体字符串 + salt)
  static String androidSignature(Map<String, String> params, String body) {
    final joined = (params.keys.toList()..sort())
        .map((k) => '$k=${params[k]}')
        .join();
    return md5
        .convert(utf8.encode('$androidSalt$joined$body$androidSalt'))
        .toString();
  }

  /// 参数密钥签名（helper.js signParamsKey，标准版）：
  /// md5(appid + salt + clientver + data)；login_by_verifycode 的 body `key` 用
  static String signParamsKey(String data) =>
      md5
          .convert(utf8
              .encode('$appid$androidSalt$clientver$data'))
          .toString();
}
