// 扫码登录链路离线单测（2026-11 实扫失败后的回归）：
//   flutter test test/qr_login_diagnostic_test.dart
//
// 用 Dio 自定义 HttpClientAdapter 注入固定响应，不联网，锁住本次修复的关键行为：
//   1) 网易云 803：code 为字符串/数值都兼容；MUSIC_U 来自响应头 Set-Cookie 或响应体 cookie；
//   2) 网易云 803 缺 MUSIC_U -> lastError 可见、不返回空凭证会话；
//   3) 网易云 800/802/网络异常 -> lastError 具体原因，不静默等待、不抛异常；
//   4) QQ：check_sig 拿不到 p_skey（302 后 200 无 Set-Cookie）-> lastError 可见；
//   5) QQ：check_sig 拿到 p_skey -> authorize 取 code -> QQLogin（字符串业务 code）完整成功链。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';

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

Map<String, List<String>> _jsonHeaders() => {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    };

ResponseBody _jsonBody(Object data,
        {int status = 200, Map<String, List<String>>? headers}) =>
    ResponseBody.fromString(jsonEncode(data), status,
        headers: {..._jsonHeaders(), ...?headers});

/// 安装假适配器并注册测试结束回收（避免影响同 isolate 后续用例）
void _installAdapter(_MockAdapter adapter) {
  final dio = JXHttp.dio;
  final original = dio.httpClientAdapter;
  dio.httpClientAdapter = adapter;
  addTearDown(() => dio.httpClientAdapter = original);
}

void main() {
  group('网易云扫码轮询（离线）', () {
    test('803 + code 为字符串：MUSIC_U 只在响应头 Set-Cookie 时也能拿到登录态', () async {
      _installAdapter(_MockAdapter((o) async {
        // eapi 协议：POST /eapi/login/qrcode/client/login（断言 /eapi/ 前缀防协议回退）
        expect(o.path, contains('/eapi/login/qrcode/client/login'));
        return _jsonBody(
          {
            'code': '803',
            'message': '授权登陆成功',
            'profile': {'nickname': '网易云测试'},
          },
          headers: {
            'set-cookie': [
              'MUSIC_U=FAKE_MUSIC_U_ABCD; Path=/; Domain=music.163.com',
              '__csrf=FAKE_CSRF; Path=/',
            ],
          },
        );
      }));
      final api = NeteaseApi();
      final session = await api.pollQrLogin('key-1');
      expect(session, isNotNull);
      expect(session!.cookies['MUSIC_U'], 'FAKE_MUSIC_U_ABCD');
      expect(session.cookies['__csrf'], 'FAKE_CSRF');
      expect(session.nickname, '网易云测试');
      expect(api.lastError, isNull);
    });

    test('803 + 响应体 cookie 字符串（旧接口格式）也能解析', () async {
      _installAdapter(_MockAdapter((o) async => _jsonBody({
            'code': 803,
            'cookie': 'MUSIC_U=BODY_MU; __csrf=CSRF; os=pc',
          })));
      final api = NeteaseApi();
      final session = await api.pollQrLogin('k');
      expect(session, isNotNull);
      expect(session!.cookies['MUSIC_U'], 'BODY_MU');
      expect(session.cookies['os'], 'pc');
      expect(session.nickname, '网易云用户');
      expect(api.lastError, isNull);
    });

    test('803 但缺少 MUSIC_U：返回 null 且 lastError 指出缺凭证', () async {
      _installAdapter(_MockAdapter(
          (o) async => _jsonBody({'code': 803, 'message': '授权登录成功'})));
      final api = NeteaseApi();
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.lastError, contains('MUSIC_U'));
    });

    test('800 二维码过期：lastError 明确，不抛异常', () async {
      _installAdapter(_MockAdapter(
          (o) async => _jsonBody({'code': 800, 'message': '二维码过期'})));
      final api = NeteaseApi();
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.lastError, contains('过期'));
    });

    test('802 已扫码待确认：给出可见提示（qrHint，非错误）', () async {
      _installAdapter(
          _MockAdapter((o) async => _jsonBody({'code': 802, 'message': '待确认'})));
      final api = NeteaseApi();
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.lastError, isNull);
      expect(api.qrHint, contains('确认'));
    });

    test('同名空 Set-Cookie（清父域）不能覆盖已拿到的 MUSIC_U', () async {
      _installAdapter(_MockAdapter((o) async => _jsonBody(
            {'code': 803, 'message': '授权登陆成功'},
            headers: {
              'set-cookie': [
                'MUSIC_U=VALID_MUSIC_U; Path=/; Domain=music.163.com',
                'MUSIC_U=; Path=/; Domain=.163.com; '
                    'Expires=Thu, 01 Jan 1970 00:00:00 GMT',
              ],
            },
          )));
      final api = NeteaseApi();
      final session = await api.pollQrLogin('k');
      expect(session, isNotNull);
      expect(session!.cookies['MUSIC_U'], 'VALID_MUSIC_U');
    });

    test('801 等待扫码：静默等待（lastError 为 null）', () async {
      _installAdapter(_MockAdapter(
          (o) async => _jsonBody({'code': 801, 'message': '等待扫码'})));
      final api = NeteaseApi();
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.lastError, isNull);
    });

    test('网络异常：lastError 具体原因，不抛异常', () async {
      _installAdapter(_MockAdapter((o) async {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.connectionError,
          message: 'mock boom',
        );
      }));
      final api = NeteaseApi();
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.lastError, contains('轮询失败'));
    });
  });

  group('QQ 扫码兑换（离线）', () {
    final qrsig = List<String>.filled(44, 'Q').join();
    List<int> fakeQrPng() {
      final bytes = List<int>.filled(40, 0);
      const magic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      for (var i = 0; i < magic.length; i++) {
        bytes[i] = magic[i];
      }

      void put(int offset, int value) {
        bytes[offset] = (value >> 24) & 0xff;
        bytes[offset + 1] = (value >> 16) & 0xff;
        bytes[offset + 2] = (value >> 8) & 0xff;
        bytes[offset + 3] = value & 0xff;
      }

      put(16, 111);
      put(20, 111);
      return bytes;
    }

    final png = fakeQrPng();
    ResponseBody show() => ResponseBody.fromBytes(png, 200, headers: {
          'set-cookie': ['qrsig=$qrsig; Path=/; Domain=ptlogin2.qq.com'],
        });
    const jumpUrl =
        'https://ptlogin2.qq.com/check_sig?uin=o0123456789&service=ptqrlogin'
        '&nodirect=0&ptsigx=PTSIGX_ABC123'
        '&s_url=https%3A%2F%2Fgraph.qq.com%2Foauth2.0%2Flogin_jump';
    ResponseBody loginOk() => ResponseBody.fromString(
        "ptuiCB('0','0','$jumpUrl','0','登录成功！','扫码昵称')", 200);

    test('check_sig 拿到 p_skey -> authorize code -> QQLogin 全链路成功', () async {
      _installAdapter(_MockAdapter((o) async {
        final path = o.path;
        if (path.contains('ptqrshow')) return show();
        if (path.contains('ptqrlogin')) return loginOk();
        if (path.contains('check_sig')) {
          // 1a 参考实现同款：不带 Cookie，p_skey 在首个 302 的 Set-Cookie 里
          expect(o.headers.containsKey('Cookie'), isFalse);
          return ResponseBody.fromString('', 302, headers: {
            'location': [
              'https://graph.qq.com/oauth2.0/login_jump?uin=o0123456789'
            ],
            'set-cookie': [
              'p_skey=FAKE_PSKEY_1234; Path=/; Domain=graph.qq.com',
              'skey=FAKE_SKEY; Path=/',
            ],
          });
        }
        if (path.contains('oauth2.0/authorize')) {
          expect('${o.headers['Cookie']}', contains('p_skey=FAKE_PSKEY_1234'));
          return ResponseBody.fromString('', 302, headers: {
            'location': [
              'https://y.qq.com/portal/wx_redirect.html?login_type=1'
                  '&surl=https://y.qq.com/&code=FAKE_CODE_XYZ'
            ],
          });
        }
        if (path.contains('cgi-bin/musicu.fcg')) {
          return _jsonBody({
            'code': 0,
            'req': {
              'code': '0', // 字符串业务 code 也兼容
              'data': {
                'musicid': 123456,
                'musickey': 'MUSICKEY_ABC',
                'nick': '数据昵称',
              },
            },
          });
        }
        return ResponseBody.fromString('unexpected: $path', 404);
      }));

      final api = QQMusicApi();
      final created = await api.createQrLogin();
      expect(created.key, qrsig);
      final session = await api.pollQrLogin(created.key);
      expect(session, isNotNull);
      expect(session!.nickname, '数据昵称');
      expect(session.cookies['uin'], '123456');
      expect(session.cookies['qqmusic_uin'], '123456');
      expect(session.cookies['qm_keyst'], 'MUSICKEY_ABC');
      expect(session.cookies['qqmusic_key'], 'MUSICKEY_ABC');
      expect(api.lastError, isNull);
    });

    test('check_sig 无 p_skey 时：带 jar 跟随 login_jump 链取 code -> QQLogin 成功', () async {
      var checkSigCount = 0;
      _installAdapter(_MockAdapter((o) async {
        final path = o.path;
        if (path.contains('ptqrshow')) return show();
        if (path.contains('ptqrlogin')) return loginOk();
        if (path.contains('check_sig')) {
          checkSigCount++;
          // 实扫证据的形态：302 → login_jump；Set-Cookie 名称含 p_skey 但值为空
          return ResponseBody.fromString('', 302, headers: {
            'location': [
              'https://graph.qq.com/oauth2.0/login_jump?uin=o0123456789'
            ],
            'set-cookie': [
              'p_skey=; Path=/; Domain=graph.qq.com',
              'pt4_token=FAKE_PT4_TOKEN; Path=/',
            ],
          });
        }
        if (path.contains('oauth2.0/login_jump')) {
          return ResponseBody.fromString('', 302, headers: {
            'location': [
              'https://y.qq.com/portal/wx_redirect.html?login_type=1'
                  '&surl=https://y.qq.com/&code=CHAIN_CODE_456'
            ],
          });
        }
        if (path.contains('oauth2.0/authorize')) {
          fail('已从 OAuth 链取到 code，不应再请求 authorize');
        }
        if (path.contains('cgi-bin/musicu.fcg')) {
          return _jsonBody({
            'code': 0,
            'req': {
              'code': 0,
              'data': {
                'musicid': 654321,
                'musickey': 'KEY_FROM_CHAIN',
                'nick': '链上用户',
              },
            },
          });
        }
        return ResponseBody.fromString('unexpected: $path', 404);
      }));

      final api = QQMusicApi();
      final created = await api.createQrLogin();
      final session = await api.pollQrLogin(created.key);
      expect(session, isNotNull);
      expect(session!.nickname, '链上用户');
      expect(session.cookies['qm_keyst'], 'KEY_FROM_CHAIN');
      expect(api.qrScanConfirmed, isTrue);
      expect(checkSigCount, 1, reason: '拿到 302 入口后不应重复请求 check_sig');
    });

    test('check_sig 始终不返回 p_skey：返回 null 且 lastError 含具体原因', () async {
      _installAdapter(_MockAdapter((o) async {
        final path = o.path;
        if (path.contains('ptqrshow')) return show();
        if (path.contains('ptqrlogin')) return loginOk();
        if (path.contains('check_sig')) {
          return ResponseBody.fromString('', 302, headers: {
            'location': ['https://www.qq.com/'],
          });
        }
        // 跟随 302 后的目标页：200 且没有 Set-Cookie
        return ResponseBody.fromString('{}', 200);
      }));

      final api = QQMusicApi();
      final created = await api.createQrLogin();
      expect(await api.pollQrLogin(created.key), isNull);
      expect(api.lastError, contains('check_sig'));
      expect(api.lastError, contains('p_skey'));
    });

    test('未取码时用无效 key 轮询：直接返回 null，不发请求', () async {
      _installAdapter(_MockAdapter((o) async {
        fail('不应发起网络请求：${o.path}');
      }));
      final api = QQMusicApi();
      expect(await api.pollQrLogin('not-a-real-qrsig'), isNull);
      expect(api.lastError, isNull);
    });

    test('同名空 Set-Cookie（清父域）不能覆盖有效 p_skey；authorize 的 g_tk 不退化为 5381', () async {
      Map<dynamic, dynamic>? authorizeData;
      const pskey = 'PSKEY_VALID_VALUE_44_CHARS_ABCDEFGHIJKLMNOP';
      _installAdapter(_MockAdapter((o) async {
        final path = o.path;
        if (path.contains('ptqrshow')) return show();
        if (path.contains('ptqrlogin')) return loginOk();
        if (path.contains('check_sig')) {
          // 复刻 2026-11-09 实扫原始顺序：先有效 p_skey，随后同名清空行
          // （服务端用于删除父域/其它 Path 的旧 cookie；不能覆盖有效值）。
          return ResponseBody.fromString('', 302, headers: {
            'location': ['https://graph.qq.com/oauth2.0/login_jump?x=1'],
            'set-cookie': [
              'p_skey=$pskey; Path=/; Domain=graph.qq.com',
              'p_skey=; Path=/; Domain=qq.com; '
                  'Expires=Thu, 01 Jan 1970 00:00:00 GMT',
              'pt4_token=TOKEN; Path=/',
            ],
          });
        }
        if (path.contains('oauth2.0/authorize')) {
          authorizeData = o.data is Map ? o.data as Map : null;
          return ResponseBody.fromString('', 302, headers: {
            'location': [
              'https://y.qq.com/portal/wx_redirect.html?login_type=1'
                  '&code=CODE_OK_123'
            ],
          });
        }
        if (path.contains('cgi-bin/musicu.fcg')) {
          return _jsonBody({
            'code': 0,
            'req': {
              'code': 0,
              'data': {
                'musicid': 111,
                'musickey': 'MK',
                'nick': '有效p_skey用户',
              },
            },
          });
        }
        return ResponseBody.fromString('unexpected: $path', 404);
      }));

      int hash33(String s, [int h = 0]) {
        var e = h;
        for (final c in s.codeUnits) {
          e += (e << 5) + c;
        }
        return 2147483647 & e;
      }

      final api = QQMusicApi();
      final created = await api.createQrLogin();
      final session = await api.pollQrLogin(created.key);
      expect(session, isNotNull);
      expect(session!.nickname, '有效p_skey用户');
      expect(authorizeData, isNotNull);
      final gTk = '${authorizeData!['g_tk']}';
      expect(gTk, isNot('5381'), reason: 'p_skey 不能被同名空 cookie 覆盖');
      expect(gTk, '${hash33(pskey, 5381)}');
    });
  });

  // 网易云 eapi 加密固定向量：由 Node/OpenSSL（crypto AES-128-ECB + md5）
  // 按参考实现（Yuanlang3/dsh-netease-music-plugin eapiBody）独立计算，
  // 用于证明 Dart/pointycastle 实现的 params 与官方协议一致。
  group('网易云 eapi 加密（固定向量）', () {
    test('unikey 请求 params 与参考实现一致', () {
      expect(
        NeteaseApi.eapiParams('/api/login/qrcode/unikey', {'type': '3'}),
        '1CA81A97B7BAEB099F29A9B99A25CD6E58E7BA5B35F25231033065C776830C0A'
        'BBBC72845BFB6CD868F6F9B7CBD2746DF59D3614BB3D33D8D3C02F073E47B374'
        'D7CA311CE3B46AC3C09B5B3F9361AAB2B29BE5508A1F6EDB199EDB363DB39B87',
      );
    });

    test('client/login 请求 params 与参考实现一致', () {
      expect(
        NeteaseApi.eapiParams('/api/login/qrcode/client/login',
            {'key': 'test-key-123', 'type': '3'}),
        '1CA81A97B7BAEB099F29A9B99A25CD6EEB07A96476EBB336CC9DE7F57581855'
        'B8F776DF5B44425C82267FA8FD6FCF4D50ACC6F255672B2C15E34FB4EC57C39F'
        '6CBA1B23E753354D30A99FB7FBE9E4EC465AAB0A7D0391AB554E577AC50E522D'
        '5000833A6F799AE0F71EC1E661A2142B3A938C12E10DCBE06B53D4DA1FF52117'
        'F',
      );
    });
  });
}
