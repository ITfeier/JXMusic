import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/kugou_login_crypto.dart';

/// 酷狗密码登录加密移植的正确性（对照 KuGouMusicApi util/crypto.js）。
///
/// 这些用例只验证纯函数契约（密钥派生、加解密往返、签名拼接、
/// RSA 形状），不发网络请求；真实登录链路联调在真机验证。
void main() {
  group('KugouLoginCrypto', () {
    test('tempKey 为 16 位数字+小写字母', () {
      for (var i = 0; i < 20; i++) {
        final key = KugouLoginCrypto.randomTempKey();
        expect(key.length, 16);
        expect(key, matches(RegExp(r'^[0-9a-z]{16}$')));
      }
    });

    test('AES key/iv 派生与 crypto.js 一致（md5 前 32 / 后 16）', () {
      const tempKey = '0123456789abcdef';
      final digest = md5.convert(utf8.encode(tempKey)).toString();
      expect(KugouLoginCrypto.aesKey(tempKey), digest.substring(0, 32));
      expect(KugouLoginCrypto.aesKey(tempKey).length, 32); // 32 字节 → AES-256
      expect(KugouLoginCrypto.aesIv(tempKey), digest.substring(16));
    });

    test('AES 加解密往返（含中文/引号，PKCS7 兼容任意长度）', () {
      const tempKey = 'abcd1234efgh5678';
      for (final plain in const [
        '{"pwd":"p@ss\\"密码","code":"","clienttime_ms":1763300000000}',
        '{"pwd":"a","code":"","clienttime_ms":1}',
        '短文本',
        'Exactly16Chars!',
      ]) {
        final hex = KugouLoginCrypto.aesEncryptHex(plain, tempKey);
        expect(hex, matches(RegExp(r'^[0-9a-f]+$')));
        expect(hex.length % 32, 0); // 整块（16 字节）且 1 字节=2 hex
        expect(KugouLoginCrypto.aesDecryptHex(hex, tempKey), plain);
      }
    });

    test('AES 解密对非法密文抛 FormatException 而非崩溃', () {
      const tempKey = '0123456789abcdef';
      expect(() => KugouLoginCrypto.aesDecryptHex('zz', tempKey),
          throwsFormatException);
      expect(() => KugouLoginCrypto.aesDecryptHex('0011', tempKey),
          throwsFormatException); // 长度非 16 字节整块
    });

    test('RSA 无填充加密：确定性 + 256 位 hex + 值域正确', () {
      const plain = '{"clienttime_ms":1763300000000,"key":"0123456789abcdef"}';
      final a = KugouLoginCrypto.rsaEncryptHex(plain);
      final b = KugouLoginCrypto.rsaEncryptHex(plain);
      expect(a, b); // 无随机填充 → 同一明文密文恒定
      expect(a.length, 256); // 128 字节 key → 固定 256 hex
      final value = BigInt.parse(a, radix: 16);
      final n = BigInt.parse(
          'c8006ed03842d2628209bd314984ca5ed6cfe06e30c95f9d4704d9c49791d7a935ba950ecb0bc8ebf5f5994f0bac927a7eb151b3c1de343303fa539c83136eccfd7d7e511e2dbce18eaa9f784c9b50d443e75865979e0a5e216e46c684066a8d6b998580bbaa22d73f5790286bb14742e83244e44db6d707ffe162c5c7002d45',
          radix: 16);
      expect(value, greaterThan(BigInt.zero));
      expect(value, lessThan(n));
    });

    test('RSA Node 参考向量（明文右补零到 128 字节再模幂）', () {
      // Node BigInt 复刻 cryptoRSAEncrypt：padded.set(buffer) 右补零后 modPow
      expect(
          KugouLoginCrypto.rsaEncryptHex(
              '{"clienttime_ms":1731740000000,"key":"abcdefgh12345678"}'),
          'a686573056f0d7908454039e96c797e15bdb79760e3090947ca6d07d8d53e6f1'
          'bb4ae1489308d69510adebf93a07482cb05155a5f775c1361bd6a3025ed459c18'
          'a750bbca136cfa0462510430cddc58eb62de0b1c797d8e4cf140f9e7de8223599'
          'aa8cc49e38e2402d8cf450a43e2603d383affa945c0d57e4bc4da3156543ed');
    });

    test('AES Node 参考向量（crypto.createCipheriv aes-256-cbc）', () {
      const tempKey = 'abcdefgh12345678';
      // login_by_pwd params（module/login.js）
      expect(
          KugouLoginCrypto.aesEncryptHex(
              '{"pwd":"test123","code":"","clienttime_ms":1731740000000}',
              tempKey),
          '2d73eb96be81f892eaf1f41927d2123869284aa034fa61e059ded72e07b75f66'
          'df66618acf683d5d7ce594e9e187aea661f565435316c8e2ae2297d6b44795d7');
      // login_by_verifycode params（module/login_cellphone.js）
      expect(
          KugouLoginCrypto.aesEncryptHex(
              '{"mobile":"13812345678","code":"123456"}', tempKey),
          '6f52a10f6557be36c5549a3d7cdaa0743e405afb3d371a192985901d7f145bd2'
          '58799817f4cd02723a6c5a27174aaaef');
    });

    test('signParamsKey Node 参考向量（时间戳毫秒）', () {
      expect(KugouLoginCrypto.signParamsKey('1731740000000'),
          '57d9a9f9666194209c5047fc44a154a3');
    });

    test('RSA 公钥模数顶字节 >= 0x80（1024 位形状）', () {
      // 从 publicRasKey PEM 解出的模数（hex，128 字节）
      const modulusHex =
          'c8006ed03842d2628209bd314984ca5ed6cfe06e30c95f9d4704d9c49791d7a935ba950ecb0bc8ebf5f5994f0bac927a7eb151b3c1de343303fa539c83136eccfd7d7e511e2dbce18eaa9f784c9b50d443e75865979e0a5e216e46c684066a8d6b998580bbaa22d73f5790286bb14742e83244e44db6d707ffe162c5c7002d45';
      expect(modulusHex.length, 256);
      final n = BigInt.parse(modulusHex, radix: 16);
      expect(n.bitLength, 1024);
    });

    test('android 签名：key 排序 + k=v 拼接 + body 夹盐 md5', () {
      final params = <String, String>{
        'uuid': '-', // 故意乱序插入，验证签名内按 key 排序
        'appid': '1005',
        'mid': '123456789012345678901234567890123',
        'dfid': '-',
        'clientver': '20489',
        'clienttime': '1763300000',
      };
      const body = '{"plat":1,"username":"tester","params":"aabb","pk":"CCDD"}';
      final sig = KugouLoginCrypto.androidSignature(params, body);
      final joined = (params.keys.toList()..sort())
          .map((k) => '$k=${params[k]}')
          .join();
      final expected = md5
          .convert(utf8.encode(
              '${KugouLoginCrypto.androidSalt}$joined$body${KugouLoginCrypto.androidSalt}'))
          .toString();
      expect(sig, expected);
      expect(sig.length, 32);
      expect(sig, sig.toLowerCase()); // 小写 hex
    });

    test('登录协议常量与 KuGouMusicApi main 分支一致', () {
      expect(KugouLoginCrypto.androidSalt, 'OIlwieks28dk2k092lksi2UIkp');
      expect(KugouLoginCrypto.appid, '1005');
      expect(KugouLoginCrypto.clientver, '20489');
      expect(KugouLoginCrypto.t1, isNotEmpty);
      expect(KugouLoginCrypto.t2, isNotEmpty);
      expect(KugouLoginCrypto.t3, 'MCwwLDAsMCwwLDAsMCwwLDA=');
    });

    test('signParamsKey：md5(appid+盐+clientver+data)，Node 参考向量', () {
      // Node: md5('1005'+'OIlwieks28dk2k092lksi2UIkp'+'20489'+data)
      expect(KugouLoginCrypto.signParamsKey('1719000000000'),
          '0c201b844df7f2076de9db0a55f3bca2');
      expect(KugouLoginCrypto.signParamsKey('0'),
          'c3f44cd3168748f7bd90d619c2fc6a43');
    });
  });
}
