import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/netease_crypto.dart';

/// eapi 算法锁定测试（参考向量由 Node crypto 按上游
/// NeteaseCloudMusicApi-enhanced util/crypto.js 生成，无随机成分）。
void main() {
  group('NeteaseCrypto.eapi', () {
    // 与 Node 参考向量完全一致的键序（jsonEncode 按插入序输出）
    Map<String, dynamic> vectorData() => <String, dynamic>{
          'type': '1',
          'https': 'true',
          'phone': '13800000000',
          'countrycode': '86',
          'password': 'e10adc3949ba59abbe56e057f20f883e',
          'remember': 'true',
          'secureCaptcha': '',
          'e_r': false,
          'header': <String, dynamic>{
            'osver': 'Microsoft-Windows-10-Professional-build-19045-64bit',
            'deviceId': '0123456789abcdef0123456789abcdef',
            'os': 'pc',
            'appver': '3.1.17.204416',
            'versioncode': '140',
            'mobilename': '',
            'buildver': '1719000000',
            'resolution': '1920x1080',
            '__csrf': '',
            'channel': 'netease',
            'requestId': '1719000000_0420',
          },
        };

    test('登录向量：AES-128-ECB 输出与 Node 参考值逐字节一致', () {
      const expected =
          '2DF3329A90E499F6DF4EC98AFF9D59CFE544D9FF5C0A1C67DF7E899637FF3479F'
          'CD5397B5D9EA1421F9005F633F1F37E9A67DA3D8D83083AE05BCC1367CBAADD887'
          'A534CEBF6CA937BE9A5A12D910A64D9742E232D2D79830E07E4ADA042046568D29'
          '12685913A4CBC10B2D4B007193020A3B3BDACA6DCBD85D5A63969214071160BAB5'
          '8BAC6393F8FB8A61AE9D164E23458372DF1126A20AFFC71391804DC5DF7DA885CCF'
          'B3E359EC16B3A8A0405E5B60EF67366A75965B13839141D8BEDB181DE13BDBD98B3'
          '5588F592AF3D7947659BACDCC87E3EA888DB19F80CA5B837ABED75AEEACD5D4E827'
          '9BBE9C03BB8D9CBEA6FD435CD714E02540159C8F84417452B0EC414E9D7092E2FF'
          '2728548A835141B8CDBE61B2493DE40EECBFD5AF1C83793FBA314D0CAD8A5CA0BA0'
          '569B8B8D5D7B2FCD03064997E3297C1AAF5C0AD91A220EBCBAB9FEF2944CA124519'
          '6132AB14EE990B92488F4E2EDEF581B0EC98763BC39E770E77FD65AF6A77C21A742'
          'DA7219555F35E4C17DA0DBB412A5E5BDC0C8055FD4FA5B94D31BB96B2DABF32F72'
          '88D2137B95672B61D576F088E6815EF26C4FCD11C466FA0A7C9F45EB5598D8F7E7E'
          '3884B508E30BB61CE6450A0FD14618F7330AC43FE2F92C526139EDB951C33BF760A'
          '9B16B719C063F7F84EE158AC10E776D57111C8118B24443A3D85125F22D3ABBF21C'
          '9291E9A23CE4733012EB3E55604436C79FA4330C374695CF9A7A30AF33C6B2ADBEA'
          'F2842F34870E612F5EACFAE6AA3B102FBE7296AB0DB9EA5C46AD12B';
      final out = NeteaseCrypto.eapi('/api/w/login/cellphone', vectorData());
      expect(out, expected);
    });

    test('无随机成分：同一输入两次加密结果一致', () {
      final a =
          NeteaseCrypto.eapi('/api/w/login/cellphone', vectorData());
      final b =
          NeteaseCrypto.eapi('/api/w/login/cellphone', vectorData());
      expect(a, b);
    });

    test('PKCS7 填充：密文长度为 16 字节整数倍', () {
      final out = NeteaseCrypto.eapi('/api/w/login', <String, dynamic>{
        'type': '0',
        'username': 'a@example.com',
        'password': 'e10adc3949ba59abbe56e057f20f883e',
        'rememberLogin': 'true',
      });
      expect(out.length % 32, 0); // hex 每字节 2 字符
      // 解密回读可验证原文结构（依赖 pointycastle ECB 对称性）
      expect(out, equals(out.toUpperCase()));
    });
  });
}
