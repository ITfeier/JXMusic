import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/kg_crypto.dart';
import 'package:jxmusic/services/api/kugou_api.dart';

/// 酷狗 Web 登录态交换加密单测（纯离线，不联网）。
///
/// 固定向量由 Node.js（crypto / BigInt modPow）按官网 `kguser.v2.min.js` 与
/// 公开仓库 makcre/KuGouMusicApi 的 `util/crypto.js` 算法现场算出后写死：
/// - AES：`abc encrypt` 约定两套密钥派生（md5 / 原始 key）
/// - RSA：textbook（零左填充）加密，两把公钥（PEM / 官网 JS 内置）
void main() {
  // 固定登录 key（16 位）与明文
  const tempKey = 'abcdefghijklmnop';
  const plain = '{"token":"0123456789abcdef0123456789abcdef"}';

  group('密钥派生', () {
    test('md5 约定：AESKey = md5(key)[0:32]，IV = 后 16 位', () {
      final keyIv = KgCrypto.md5KeyIv(tempKey);
      expect(KgCrypto.md5Hex(tempKey),
          '1d64dce239c4437b7736041db089e1b9');
      expect(keyIv.key, '1d64dce239c4437b7736041db089e1b9');
      expect(keyIv.iv, '7736041db089e1b9');
      expect(keyIv.key.length, 32);
      expect(keyIv.iv.length, 16);
    });

    test('Web 约定：key 与 IV 都等于 16 位随机 key', () {
      final keyIv = KgCrypto.webKeyIv(tempKey);
      expect(keyIv.key, tempKey);
      expect(keyIv.iv, tempKey);
    });

    test('randomKey16 为 16 位小写字母/数字', () {
      final key = KgCrypto.randomKey16(Random(42));
      expect(key.length, 16);
      expect(RegExp(r'^[a-z0-9]{16}$').hasMatch(key), isTrue);
      expect(KgCrypto.randomKey16(Random(42)), key); // 同种子可复现
    });
  });

  group('AES-CBC/PKCS7', () {
    // Node 向量：aes-256-cbc, key=md5hex 32 字符, iv=key 后 16 字符
    const md5Cipher =
        '02df881dd25b26ddc7fbd7d943df76a864330ab1c658e69a5bb527d1d9ac8a6e'
        '0a3437728c4667ea7b5270ab08519a53';
    // Node 向量：aes-128-cbc, key=iv=abcdefghijklmnop
    const webCipher =
        '1e00740d059f46bb050d10c842f91898933e74955ea696c0fb26c43ef950ff24'
        '64936988fff5dd3eaee24e49b3a165ae';

    test('md5 约定固定向量 + 解密往返', () {
      final keyIv = KgCrypto.md5KeyIv(tempKey);
      expect(KgCrypto.aesCbcEncryptHex(plain, keyIv.key, keyIv.iv), md5Cipher);
      expect(KgCrypto.aesCbcDecryptHex(md5Cipher, keyIv.key, keyIv.iv), plain);
    });

    test('Web 约定固定向量 + 解密往返', () {
      final keyIv = KgCrypto.webKeyIv(tempKey);
      expect(KgCrypto.aesCbcEncryptHex(plain, keyIv.key, keyIv.iv), webCipher);
      expect(KgCrypto.aesCbcDecryptHex(webCipher, keyIv.key, keyIv.iv), plain);
    });

    test('密文/填充非法时抛 FormatException', () {
      final keyIv = KgCrypto.md5KeyIv(tempKey);
      expect(() => KgCrypto.aesCbcDecryptHex('00', keyIv.key, keyIv.iv),
          throwsFormatException);
      // 随机密文解开后 PKCS7 填充大概率非法
      final garbage = List<int>.generate(32, (i) => 0x41).toList();
      expect(
          () => KgCrypto.aesCbcDecryptHex(
              KgCrypto.toHex(garbage), keyIv.key, keyIv.iv),
          throwsFormatException);
    });

    test('AES 密钥/IV 长度校验', () {
      expect(() => KgCrypto.aesCbcEncryptHex(plain, 'short', tempKey),
          throwsArgumentError);
      expect(() => KgCrypto.aesCbcEncryptHex(plain, tempKey, 'short'),
          throwsArgumentError);
    });
  });

  group('RSA（textbook / 零左填充）', () {
    const pkPlain =
        '{"clienttime_ms":1762531200000,"key":"abcdefghijklmnop"}';
    // Node 向量（modPow，e=65537）
    const pemCipher =
        '4693705d28eab2dc2ed270f26e5f2026dbb0ed9021be354358140663a841496e'
        '83e260d93445225b454bf525eb6d00fdca87f9f14d427d54a0b964facd5ed7bd'
        'c58e868eb20dae0a4db4a197c3e316b1565669e70b5ff57c0bdaa1f55b8bc91a'
        '007e616ed6d9f817f50f2a5fcabbce728d8efcdd737018821d0ac70f2efed88e';
    const webCipher =
        '2be78a1efb6f25fb22346ce35f7771f891e97e73dd939eb6a0bc34538e790433'
        '5918cb70e35cafffca4194e51a75acb80f819401e473400cf711f90632f45673'
        'e6ff7ac0980c50a29f52321b747d650b96e44f78a65eae22fb1befc88b1e888a'
        'c841804927d7f1080ed71c694acced105793eeea7290009a099149408b70cf23';
    const pemModulus =
        'c8006ed03842d2628209bd314984ca5ed6cfe06e30c95f9d4704d9c49791d7a9'
        '35ba950ecb0bc8ebf5f5994f0bac927a7eb151b3c1de343303fa539c83136ecc'
        'fd7d7e511e2dbce18eaa9f784c9b50d443e75865979e0a5e216e46c684066a8d'
        '6b998580bbaa22d73f5790286bb14742e83244e44db6d707ffe162c5c7002d45';

    test('PEM(DER) 解析出与已知公钥一致的模数', () {
      expect(KgCrypto.pemPublicKeyModulusHex(), pemModulus);
      expect(pemModulus.length, 256);
      expect(BigInt.parse(pemModulus, radix: 16).bitLength, 1024);
    });

    test('官网 JS 内置公钥是另一把 1024 bit 密钥', () {
      expect(KgCrypto.webPublicModulusHex.length, 256);
      expect(BigInt.parse(KgCrypto.webPublicModulusHex, radix: 16).bitLength,
          1024);
      expect(KgCrypto.webPublicModulusHex.toLowerCase(), isNot(pemModulus));
    });

    test('PEM 公钥固定向量：256 位 hex、小写、c < n', () {
      final cipher = KgCrypto.rsaRawEncryptHex(pkPlain);
      expect(cipher, pemCipher);
      expect(cipher.length, 256);
      expect(cipher, cipher.toLowerCase());
      final n = BigInt.parse(pemModulus, radix: 16);
      expect(BigInt.parse(cipher, radix: 16) < n, isTrue);
    });

    test('官网 JS 内置公钥固定向量：256 位 hex、小写、c < n', () {
      final cipher = KgCrypto.rsaRawEncryptHex(
        pkPlain,
        modulusHex: KgCrypto.webPublicModulusHex,
      );
      expect(cipher, webCipher);
      expect(cipher.length, 256);
      final n = BigInt.parse(KgCrypto.webPublicModulusHex, radix: 16);
      expect(BigInt.parse(cipher, radix: 16) < n, isTrue);
    });

    test('明文超过密钥长度时抛 ArgumentError', () {
      final tooLong = 'a' * 129;
      expect(() => KgCrypto.rsaRawEncryptHex(tooLong), throwsArgumentError);
    });

    test('明文长度不足时零左填充（小明文也能加密到 128 字节）', () {
      final cipher = KgCrypto.rsaRawEncryptHex('hi');
      expect(cipher.length, 256);
    });
  });

  group('hex 工具', () {
    test('toHex/fromHex 往返', () {
      final bytes = List<int>.generate(256, (i) => (i * 37) % 256);
      final hex = KgCrypto.toHex(bytes);
      expect(hex.length, 512);
      expect(KgCrypto.fromHex(hex), bytes);
    });

    test('非法 hex 抛 FormatException', () {
      expect(() => KgCrypto.fromHex('abc'), throwsFormatException);
      expect(() => KgCrypto.fromHex('zz'), throwsFormatException);
      expect(() => KgCrypto.fromHex(''), throwsFormatException);
    });
  });

  group('secu_params 解密（模拟服务端响应）', () {
    test('md5 约定加密的 JSON 可用同约定解出', () {
      final keyIv = KgCrypto.md5KeyIv(tempKey);
      final plaintext = jsonEncode({
        'userid': '123456789',
        'token': 'abcdef0123456789',
        'vip_type': '1',
        'vip_token': 'vip-token-xyz',
      });
      final cipher = KgCrypto.aesCbcEncryptHex(plaintext, keyIv.key, keyIv.iv);
      final decoded = jsonDecode(
          KgCrypto.aesCbcDecryptHex(cipher, keyIv.key, keyIv.iv));
      expect(decoded, isA<Map<String, dynamic>>());
      expect((decoded as Map)['vip_type'], '1');
    });
  });

  group('失败降级（离线，不联网）', () {
    test('pollQrLogin 对非本次取码 key 立即返回 null，不抛异常', () async {
      final api = KuGouApi();
      expect(await api.pollQrLogin('not-a-real-key'), isNull);
      expect(await api.pollQrLogin(''), isNull);
      expect(api.lastError, isNull);
    });
  });
}
