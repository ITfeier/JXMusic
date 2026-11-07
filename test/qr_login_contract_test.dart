// QA 契约测试（qing / 清朝·质量与安全）：
//   flutter test test/qr_login_contract_test.dart
//
// 目的：在不联网的前提下，静态/运行期锁定本次修复承诺的接口契约与「未扫码不抛异常」语义：
//   1. createQrLogin() 返回 ({String qrUrl, String key})；pollQrLogin(String)
//      返回 Future<AccountSession?>（与 MusicPlatformApi 声明逐字一致）；
//   2. 三个平台实现都实现 MusicPlatformApi（新增 lastError 后无编译期破坏）；
//   3. 未持有有效 key 时 pollQrLogin 直接返回 null，不发起请求、不抛异常；
//   4. lastError 默认语义：无失败时为 null（网易云未实现具体原因，保持默认 null）。
//
// 注意：这里不调用 createQrLogin()（会真实联网），联网链路由
// test/qr_http_probe.dart 与 tool/check_qq_qr.dart、tool/check_kg_qr_probe.dart 覆盖。
import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';

void main() {
  group('扫码登录接口契约', () {
    test('createQrLogin 返回记录类型 ({String qrUrl, String key})', () {
      // 赋值给显式函数类型：若返回类型被改动，这里编译失败。
      final Future<({String qrUrl, String key})> Function() f =
          QQMusicApi().createQrLogin;
      final Future<({String qrUrl, String key})> Function() g =
          KuGouApi().createQrLogin;
      final Future<({String qrUrl, String key})> Function() h =
          NeteaseApi().createQrLogin;
      expect(f, isA<Function>());
      expect(g, isA<Function>());
      expect(h, isA<Function>());
    });

    test('pollQrLogin 返回 Future<AccountSession?>', () {
      final Future<AccountSession?> Function(String) f =
          QQMusicApi().pollQrLogin;
      final Future<AccountSession?> Function(String) g =
          KuGouApi().pollQrLogin;
      final Future<AccountSession?> Function(String) h =
          NeteaseApi().pollQrLogin;
      expect(f, isA<Function>());
      expect(g, isA<Function>());
      expect(h, isA<Function>());
    });

    test('三个平台均实现 MusicPlatformApi 且暴露 lastError', () {
      final apis = <MusicPlatformApi>[
        QQMusicApi(),
        NeteaseApi(),
        KuGouApi(),
      ];
      expect(apis.map((e) => e.platform).toSet(), {0, 1, 2});
      for (final api in apis) {
        expect(api.lastError, isNull,
            reason: '新建实例尚无扫码操作，lastError 应为 null');
        expect(api.lastError, isA<String?>());
      }
    });

    test('无有效 key 时 pollQrLogin 直接返回 null（不发请求、不抛异常）', () async {
      final qq = QQMusicApi();
      final kg = KuGouApi();
      qq.restoreSession(null);
      kg.restoreSession(null);
      // 空 key / 未创建过二维码的 key：必须快速返回 null 而不是抛异常
      expect(await qq.pollQrLogin(''), isNull);
      expect(await qq.pollQrLogin('not-a-real-qrsig'), isNull);
      expect(await kg.pollQrLogin(''), isNull);
      expect(await kg.pollQrLogin('not-a-real-kg-key'), isNull);
    });

    test('restoreSession(null) 不抛异常且不改变 lastError 语义', () {
      final qq = QQMusicApi();
      final kg = KuGouApi();
      final ne = NeteaseApi();
      expect(() => qq.restoreSession(null), returnsNormally);
      expect(() => kg.restoreSession(null), returnsNormally);
      expect(() => ne.restoreSession(null), returnsNormally);
      expect(qq.lastError, isNull);
      expect(kg.lastError, isNull);
      expect(ne.lastError, isNull);
    });
  });
}
