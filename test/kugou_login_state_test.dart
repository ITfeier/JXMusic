// 酷狗登录态修复的离线单测（2026-11-09）。
//   flutter test test/kugou_login_state_test.dart
//
// 覆盖：
//   1) Web 签名 / 设备 MID / 云歌单 AES 的**固定向量**（由 Node/OpenSSL 按参考实现
//      MakcRe/KuGouMusicApi 独立算出，非本实现自证）；
//   2) 扫码 status=4 时直接用 token+userid 建立会话，**不再调用 legacy
//      login_by_token_get**，且 lastError 不再出现"登录态不完整"（误报回归）；
//   3) 二维码过期 / 轮询错误码 / 取链带登录 Cookie 的行为。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/kg_crypto.dart';
import 'package:jxmusic/services/api/kugou_api.dart';

class _MockAdapter implements HttpClientAdapter {
  _MockAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonBody(Object data) => ResponseBody.fromString(jsonEncode(data), 200,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });

void _installAdapter(_MockAdapter adapter) {
  final dio = JXHttp.dio;
  final original = dio.httpClientAdapter;
  dio.httpClientAdapter = adapter;
  addTearDown(() => dio.httpClientAdapter = original);
}

void main() {
  group('酷狗 Web 签名固定向量（Node/OpenSSL 独立算得）', () {
    test('QR 取码参数签名一致', () {
      // Node: md5(salt + sorted "k=v" + salt).toUpperCase()
      //   参数与 kugou_api.createQrLogin 一致（clienttime 固定为 1700000000000）
      expect(
        KgCrypto.signWeb({
          'appid': '1014',
          'clientver': '8131',
          'clienttime': '1700000000000',
          'dfid': '-',
          'mid': '0123456789abcdef0123456789abcdef',
          'plat': '4',
          'qrcode_txt':
              'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1014&',
          'type': '1',
          'uuid': '0123456789abcdef0123456789abcdef',
        }),
        'f21edc2ec93af9d9d9e1eb5c355ca34c',
      );
    });

    test('简单参数签名', () {
      expect(
        KgCrypto.signWeb({'a': '1', 'b': '2'}),
        '70ccbef64fdcc9271fe883d1d7f07395',
      );
    });
  });

  group('酷狗设备 MID / 云歌单 AES（Node/OpenSSL 独立算得）', () {
    test('calculateMid("abc") 与 Node BigInt 结果一致', () {
      expect(
        KgCrypto.calculateMid('abc'),
        '191415658344158766168031473277922803570',
      );
    });

    test('playlistAesDecrypt 能解开 Node 生成的 base64 密文', () {
      // Node: key='abc123' → md5[0:16] 作 AESKey、md5[16:32] 作 IV，AES-128-CBC/PKCS7
      final decoded = KgCrypto.playlistAesDecrypt(
        '3aq3jMRUVfcQebeFZyJ8JcknuzsQjNYdrp/uC5oDzWU=',
        'abc123',
      );
      expect(decoded['dfid'], 'TEST_DFID_123');
    });
  });

  group('酷狗扫码登录（离线）', () {
    test('status=4 直接用 token+userid 建立会话，不再调 legacy 换登录态', () async {
      var polls = 0;
      _installAdapter(_MockAdapter((o) async {
        final path = o.path;
        if (path.contains('/v2/qrcode')) {
          return _jsonBody({
            'status': 1,
            'data': {
              'qrcode': 'QRKEY123',
              'qrcode_img': 'data:image/png;base64,AAAA',
            },
          });
        }
        if (path.contains('/v2/get_userinfo_qrcode')) {
          polls++;
          if (polls == 1) {
            return _jsonBody({
              'status': 1,
              'data': {'status': 1},
            });
          }
          if (polls == 2) {
            return _jsonBody({
              'status': 1,
              'data': {'status': 2},
            });
          }
          return _jsonBody({
            'status': 1,
            'data': {
              'status': 4,
              'token': 'TOKEN_ABC',
              'userid': '1000000000',
              'nickname': '测试用户',
            },
          });
        }
        // 回归守卫：legacy 换登录态接口已删除，绝不能再被调用
        if (path.contains('login_by_token') ||
            path.contains('loginservice')) {
          fail('不应调用 legacy login_by_token_get：$path');
        }
        return _jsonBody({'status': 0});
      }));

      final api = KuGouApi();
      final created = await api.createQrLogin();
      expect(created.key, 'QRKEY123');
      expect(await api.pollQrLogin(created.key), isNull); // 等待扫码
      expect(await api.pollQrLogin(created.key), isNull); // 待确认
      final session = await api.pollQrLogin(created.key);
      expect(session, isNotNull);
      expect(session!.cookies['token'], 'TOKEN_ABC');
      expect(session.cookies['userid'], '1000000000');
      expect(session.nickname, '测试用户');
      expect(api.lastError, isNull);
      expect('${api.lastError}', isNot(contains('登录态不完整')));
    });

    test('二维码过期给出准确 lastError', () async {
      var polled = false;
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('/v2/qrcode')) {
          return _jsonBody({
            'status': 1,
            'data': {'qrcode': 'K'},
          });
        }
        polled = true;
        return _jsonBody({
          'status': 1,
          'data': {'status': 0},
        });
      }));
      final api = KuGouApi();
      final created = await api.createQrLogin();
      expect(await api.pollQrLogin(created.key), isNull);
      expect(polled, isTrue);
      expect(api.lastError, contains('过期'));
    });

    test('轮询 error_code 非 0 时给出具体原因', () async {
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('/v2/qrcode')) {
          return _jsonBody({
            'status': 1,
            'data': {'qrcode': 'K'},
          });
        }
        return _jsonBody({
          'status': 0,
          'error_code': 20028,
          'data': null,
        });
      }));
      final api = KuGouApi();
      final created = await api.createQrLogin();
      expect(await api.pollQrLogin(created.key), isNull);
      expect(api.lastError, contains('20028'));
    });

    test('登录后取链请求会带 token/userid Cookie（本机实测可播路径）', () async {
      String? cookieHeader;
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('/v2/qrcode')) {
          return _jsonBody({
            'status': 1,
            'data': {'qrcode': 'K'},
          });
        }
        if (o.path.contains('/v2/get_userinfo_qrcode')) {
          return _jsonBody({
            'status': 1,
            'data': {
              'status': 4,
              'token': 'TOKEN_ABC',
              'userid': '1000000000',
              'nickname': '测试用户',
            },
          });
        }
        if (o.path.contains('getSongInfo')) {
          cookieHeader = '${o.headers['Cookie']}';
          return _jsonBody({
            'status': 1,
            'url': 'https://sharefs.kugou.com/test.mp3',
          });
        }
        return _jsonBody({});
      }));
      final api = KuGouApi();
      final created = await api.createQrLogin();
      final session = await api.pollQrLogin(created.key);
      expect(session, isNotNull);
      api.restoreSession(session);
      final url = await api.getPlayUrl(const Song(
        id: '48C685F6E0E4C55F6C0F8B7B2D1CA9DB44',
        platform: 2,
        title: '晴天',
        artist: '周杰伦',
        album: '',
        coverUrl: '',
        duration: 269,
        vip: false,
      ));
      expect(url, 'https://sharefs.kugou.com/test.mp3');
      expect(cookieHeader, contains('token=TOKEN_ABC'));
      expect(cookieHeader, contains('userid=1000000000'));
    });
  });
}
