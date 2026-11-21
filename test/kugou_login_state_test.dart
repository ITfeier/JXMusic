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
      // PowerShell: md5(salt + sorted "k=v" + salt)
      //   参数与 kugou_api.createQrLogin 一致（clienttime 固定为 1700000000，
      //   appid=1001 Android 客户端型二维码，2026-11-19 起）
      expect(
        KgCrypto.signWeb({
          'appid': '1001',
          'clientver': '20489',
          'clienttime': '1700000000',
          'dfid': '-',
          'mid': '123456789012345678901234567890',
          'plat': '4',
          'srcappid': '2919',
          'qrcode_txt':
              'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1005&',
          'type': '1',
          'uuid': '-',
        }),
        '9def37900e26cd21ec137dd03f7c8ec2',
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
      Map<String, dynamic> createQuery = {};
      Map<String, dynamic> pollQuery = {};
      _installAdapter(_MockAdapter((o) async {
        final path = o.path;
        if (path.contains('/v2/qrcode')) {
          createQuery = Map<String, dynamic>.of(o.queryParameters);
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
          pollQuery = Map<String, dynamic>.of(o.queryParameters);
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
      // 2026-11-19：Android 客户端型二维码（appid=1001 取码 / 1005 轮询），
      // H5（1014）token 被 cloudlist get_all_list 拒 20017（真机实测）
      expect('${createQuery['appid']}', '1001');
      expect('${createQuery['srcappid']}', '2919');
      expect('${createQuery['clientver']}', '20489');
      expect('${createQuery['qrcode_txt']}', contains('appid=1005&'));
      expect('${createQuery['signature']}', isNotEmpty);
      expect(await api.pollQrLogin(created.key), isNull); // 等待扫码
      expect('${pollQuery['appid']}', '1005');
      expect('${pollQuery['srcappid']}', '2919');
      expect('${pollQuery['clientver']}', '20489');
      expect('${pollQuery['qrcode']}', 'QRKEY123');
      expect(await api.pollQrLogin(created.key), isNull); // 待确认
      final session = await api.pollQrLogin(created.key);
      expect(session, isNotNull);
      expect(session!.cookies['token'], 'TOKEN_ABC');
      expect(session.cookies['userid'], '1000000000');
      // 设备 mid 持久化进会话：账号歌单请求与登录共用设备身份
      expect(session.cookies['kg_mid'], isNotNull);
      expect(
        RegExp(r'^\d+$').hasMatch(session.cookies['kg_mid'] ?? ''),
        isTrue,
        reason: 'kg_mid 应为十进制 mid',
      );
      // 登录与取码使用同一 mid
      expect('${pollQuery['mid']}', session.cookies['kg_mid']);
      expect('${createQuery['mid']}', session.cookies['kg_mid']);
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

    test('账号歌单请求使用会话 kg_mid，与登录 mid 一致（20017 回归）', () async {
      Map<String, dynamic> listQuery = {};
      Map<String, dynamic> listBody = {};
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
        if (o.path.contains('/v7/get_all_list')) {
          listQuery = Map<String, dynamic>.of(o.queryParameters);
          listBody = o.data is String
              ? Map<String, dynamic>.from(jsonDecode(o.data as String) as Map)
              : {};
          return _jsonBody({
            'status': 1,
            'error_code': 0,
            'data': {
              'list': [
                {'specialid': 111, 'specialname': '我的歌单', 'count': 3},
              ],
            },
          });
        }
        return _jsonBody({});
      }));
      final api = KuGouApi();
      final created = await api.createQrLogin();
      final session = await api.pollQrLogin(created.key);
      expect(session, isNotNull);
      final lists = await api.userPlaylists();
      expect(lists, isNotEmpty);
      expect(lists.first.title, '我的歌单');
      // get_all_list 的设备 mid 必须取会话 kg_mid（与扫码登录一致），
      // 而不是匿名搜索 mid（旧实现被网关拒 20017 的诱因之一）
      expect('${listQuery['mid']}', session!.cookies['kg_mid']);
      expect('${listBody['token']}', 'TOKEN_ABC');
      expect('${listBody['userid']}', '1000000000');
      expect('${listBody['total_ver']}', '979');
      expect('${listQuery['plat']}', '1');
    });
  });
}
