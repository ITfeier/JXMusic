// QA 残留问题回归（离线，不联网）：
//   flutter test test/residual_fixes_test.dart
//
// 覆盖（对照 docs/projects/扫码登录修复/测试报告-实扫验收.md 第六节 + 播放失败诊断 P1）：
//   · D-05：三平台扫码终态 qrTerminal（网易云 800/8821、QQ 65、酷狗 status=0）
//           提前置位、等待态复位、重新取码重置；
//   · D-11：QQ extractOAuthCode 认 `#code=` fragment 形态；
//   · #3/#6：getPlayUrl 失败的具体原因写入 lastError
//           （网易云 -110 VIP、QQ 104003 节目类、酷狗 付费）；
//   · #5：酷狗歌单 page=1 聚合整单（内部翻页 + 首元素防重守卫）、page>1 本地切片；
//   · 播放失败诊断 P1：similarArtist / durationClose / isOddVersion 纯函数；
//   · 换平台提示：PlayerService.reportSourceSwitch / clearSourceSwitchNotice。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';
import 'package:jxmusic/services/playback.dart';
import 'package:jxmusic/services/player_service.dart';

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

void _installAdapter(_MockAdapter adapter) {
  final dio = JXHttp.dio;
  final original = dio.httpClientAdapter;
  dio.httpClientAdapter = adapter;
  addTearDown(() => dio.httpClientAdapter = original);
}

List<int> _fakeQrPng() {
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

Map<String, dynamic> _kgSong(int i) => {
      'hash': 'HASH${i.toString().padLeft(3, '0')}',
      'filename': '测试歌手 - 测试歌曲$i',
      'duration': 200 + i,
      'privilege': 0,
      'trans_param': {'union_cover': ''},
    };

void main() {
  group('扫码终态 qrTerminal（QA D-05）', () {
    test('网易云 801 等待 / 802 待确认：非终态', () async {
      var code = 801;
      _installAdapter(_MockAdapter((o) async =>
          _jsonBody({'code': code, 'message': '等待扫码'})));
      final api = NeteaseApi();
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.qrTerminal, isFalse);
      expect(api.lastError, isNull);
      code = 802;
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.qrTerminal, isFalse);
      expect(api.lastError, isNull);
    });

    test('网易云 800 过期：终态 + 过期文案', () async {
      _installAdapter(_MockAdapter(
          (o) async => _jsonBody({'code': 800, 'message': '二维码过期'})));
      final api = NeteaseApi();
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.qrTerminal, isTrue);
      expect(api.lastError, contains('过期'));
    });

    test('网易云 8821 风控：终态 + 风控文案', () async {
      _installAdapter(_MockAdapter((o) async => _jsonBody(
          {'code': 8821, 'message': '请切换其他登录方式或升级新版本再试'})));
      final api = NeteaseApi();
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.qrTerminal, isTrue);
      expect(api.lastError, contains('8821'));
    });

    test('网易云 重新取码重置终态', () async {
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('/eapi/login/qrcode/unikey')) {
          return _jsonBody({'unikey': 'NEW_UNIKEY_123'});
        }
        return _jsonBody({'code': 800, 'message': '二维码过期'});
      }));
      final api = NeteaseApi();
      expect(await api.pollQrLogin('k'), isNull);
      expect(api.qrTerminal, isTrue);
      final created = await api.createQrLogin();
      expect(created.key, 'NEW_UNIKEY_123');
      expect(api.qrTerminal, isFalse);
    });

    test('QQ 66 未扫 / 67 待确认：非终态', () async {
      final qrsig = List<String>.filled(44, 'Q').join();
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('ptqrshow')) {
          return ResponseBody.fromBytes(_fakeQrPng(), 200, headers: {
            'set-cookie': ['qrsig=$qrsig; Path=/; Domain=ptlogin2.qq.com'],
          });
        }
        return ResponseBody.fromString(
            "ptuiCB('66','0','','0','继续扫码中','')", 200);
      }));
      final api = QQMusicApi();
      final created = await api.createQrLogin();
      expect(created.key, qrsig);
      expect(await api.pollQrLogin(created.key), isNull);
      expect(api.qrTerminal, isFalse);
      expect(api.lastError, isNull);
    });

    test('QQ 65 过期：终态 + 过期文案 + 重新取码重置', () async {
      final qrsig = List<String>.filled(44, 'Q').join();
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('ptqrshow')) {
          return ResponseBody.fromBytes(_fakeQrPng(), 200, headers: {
            'set-cookie': ['qrsig=$qrsig; Path=/; Domain=ptlogin2.qq.com'],
          });
        }
        return ResponseBody.fromString(
            "ptuiCB('65','0','','0','二维码已失效','')", 200);
      }));
      final api = QQMusicApi();
      final created = await api.createQrLogin();
      expect(await api.pollQrLogin(created.key), isNull);
      expect(api.qrTerminal, isTrue);
      expect(api.lastError, contains('过期'));
      // 重新取码：终态复位，设置页可重新开始轮询
      await api.createQrLogin();
      expect(api.qrTerminal, isFalse);
    });

    test('酷狗 status=2 待确认非终态 / status=0 过期终态 / 重新取码重置', () async {
      var status = 2;
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('v2/qrcode')) {
          return _jsonBody({
            'data': {
              'qrcode': 'KRCODE123',
              'qrcode_img': 'data:image/png;base64,AAAA',
            }
          });
        }
        return _jsonBody({'data': {'status': status}});
      }));
      final api = KuGouApi();
      final created = await api.createQrLogin();
      expect(created.key, 'KRCODE123');
      expect(await api.pollQrLogin(created.key), isNull);
      expect(api.qrTerminal, isFalse);
      status = 0;
      expect(await api.pollQrLogin(created.key), isNull);
      expect(api.qrTerminal, isTrue);
      expect(api.lastError, contains('过期'));
      await api.createQrLogin();
      expect(api.qrTerminal, isFalse);
    });
  });

  group('getPlayUrl 失败原因写入 lastError（播放失败诊断 P1 文案化）', () {
    test('网易云 -110（VIP 未登录）：返回 null 且 lastError 说明 VIP', () async {
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('/song/enhance/player/url')) {
          return _jsonBody({
            'data': [
              {'url': null, 'code': -110, 'br': 320000},
            ],
          });
        }
        // weapi 兜底也拿不到
        return _jsonBody({'code': -460});
      }));
      final api = NeteaseApi();
      final url = await api.getPlayUrl(
          const Song(id: '999', platform: 1, title: '测试', artist: '测试'));
      expect(url, isNull);
      expect(api.lastError, contains('VIP'));
      expect(api.lastError, contains('网易云'));
    });

    test('QQ 104003（节目/电台类）：返回 null 且 lastError 说明节目类（QA #6）', () async {
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('musicu.fcg')) {
          return _jsonBody({
            'req_0': {'code': 104003},
          });
        }
        return ResponseBody.fromString('unexpected: ${o.path}', 404);
      }));
      final api = QQMusicApi();
      final url = await api.getPlayUrl(
          const Song(id: 'SONGMID001', platform: 0, title: '测试', artist: '测试'));
      expect(url, isNull);
      expect(api.lastError, contains('节目/电台类'));
      expect(api.lastError, contains('QQ音乐'));
    });

    test('酷狗 付费歌（status=0 error=需要付费）：返回 null 且 lastError 说明付费（QA #3）', () async {
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('getSongInfo.php')) {
          return _jsonBody({'status': 0, 'error': '需要付费', 'url': null});
        }
        // wwwapi 兜底也拿不到
        return _jsonBody({'data': {'play_url': ''}});
      }));
      final api = KuGouApi();
      final url = await api.getPlayUrl(
          const Song(id: 'KGHASH123', platform: 2, title: '测试', artist: '测试'));
      expect(url, isNull);
      expect(api.lastError, contains('需要付费'));
      expect(api.lastError, contains('会员或付费'));
    });

    test('酷狗 免费歌（status=1）：返回直链且无 lastError', () async {
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('getSongInfo.php')) {
          return _jsonBody(
              {'status': 1, 'url': 'http://dl.kugou.com/free.mp3'});
        }
        return ResponseBody.fromString('unexpected: ${o.path}', 404);
      }));
      final api = KuGouApi();
      final url = await api.getPlayUrl(
          const Song(id: 'KGHASH456', platform: 2, title: '测试', artist: '测试'));
      // +43 真机修复：明文直链统一升级 https（设备端 libmpv 打不开 http://）
      expect(url, 'https://dl.kugou.com/free.mp3');
      expect(api.lastError, isNull);
    });
  });

  group('QQ extractOAuthCode（QA D-11）', () {
    test('query 形态 ?code= 正常提取', () {
      expect(
        extractOAuthCode(
            'https://y.qq.com/portal/wx_redirect.html?login_type=1'
            '&surl=https://y.qq.com/&code=ABC12345'),
        'ABC12345',
      );
    });

    test('fragment 形态 #code= 也能提取（D-11：旧正则不认）', () {
      expect(
        extractOAuthCode(
            'https://y.qq.com/portal/wx_redirect.html#code=FRAG_CODE_789'),
        'FRAG_CODE_789',
      );
    });

    test('errcode / retcode 等干扰词不误匹配', () {
      expect(extractOAuthCode('https://x.com/callback?errcode=12345678'), '');
      expect(extractOAuthCode('https://x.com/callback?retcode=87654321'), '');
    });

    test('过短（<8 位）与空文本不提取', () {
      expect(extractOAuthCode('https://x.com/cb?code=ABC123'), '');
      expect(extractOAuthCode(''), '');
    });

    test('body 里的 code= 链接也能提取（authorize HTML 场景）', () {
      expect(
        extractOAuthCode(
            "<script>window.location.href='https://graph.qq.com/cb?code=BODY_CODE_42'</script>"),
        'BODY_CODE_42',
      );
    });
  });

  group('酷狗歌单分页契约（QA #5）', () {
    final playlist =
        const Playlist(id: '777', platform: 2, title: '大歌单', songCount: 130);

    test('page=1 聚合整单：>100 首时内部按 100 条/页翻页', () async {
      final requestedPages = <int>[];
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('special/song')) {
          final page = int.tryParse('${o.queryParameters['page']}') ?? 0;
          requestedPages.add(page);
          if (page == 1) {
            return _jsonBody({
              'data': {'info': [for (var i = 0; i < 100; i++) _kgSong(i)]},
            });
          }
          return _jsonBody({
            'data': {'info': [for (var i = 100; i < 130; i++) _kgSong(i)]},
          });
        }
        return ResponseBody.fromString('unexpected: ${o.path}', 404);
      }));
      final api = KuGouApi();
      final songs = await api.playlistSongs(playlist);
      expect(songs.length, 130);
      expect(requestedPages, [1, 2]);
      expect(songs.first.id, 'HASH000');
      expect(songs.last.id, 'HASH129');
    });

    test('接口忽略 page 参数时：首元素防重守卫，不堆叠重复页', () async {
      final requestedPages = <int>[];
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('special/song')) {
          final page = int.tryParse('${o.queryParameters['page']}') ?? 0;
          requestedPages.add(page);
          // 永远返回第一页
          return _jsonBody({
            'data': {'info': [for (var i = 0; i < 100; i++) _kgSong(i)]},
          });
        }
        return ResponseBody.fromString('unexpected: ${o.path}', 404);
      }));
      final api = KuGouApi();
      final songs = await api.playlistSongs(playlist);
      expect(songs.length, 100, reason: '不能把同一页堆叠多份');
      expect(songs.map((s) => s.id).toSet().length, 100,
          reason: '不能出现重复歌曲');
      expect(requestedPages, [1, 2], reason: '第 2 页发现首元素相同即停');
    });

    test('page>1 本地切片兑现分页（与 QQ 语义对齐）', () async {
      _installAdapter(_MockAdapter((o) async {
        if (o.path.contains('special/song')) {
          final page = int.tryParse('${o.queryParameters['page']}') ?? 0;
          if (page == 1) {
            return _jsonBody({
              'data': {'info': [for (var i = 0; i < 100; i++) _kgSong(i)]},
            });
          }
          return _jsonBody({
            'data': {'info': [for (var i = 100; i < 130; i++) _kgSong(i)]},
          });
        }
        return ResponseBody.fromString('unexpected: ${o.path}', 404);
      }));
      final api = KuGouApi();
      final page2 = await api.playlistSongs(playlist, page: 2, size: 50);
      expect(page2.length, 50);
      expect(page2.first.id, 'HASH050');
      expect(page2.last.id, 'HASH099');
      final page3 = await api.playlistSongs(playlist, page: 3, size: 50);
      expect(page3.length, 30);
      expect(page3.first.id, 'HASH100');
      expect(page3.last.id, 'HASH129');
    });
  });

  group('跨平台兜底校验纯函数（播放失败诊断 P1）', () {
    test('similarArtist：同歌手/多歌手/未知歌手', () {
      expect(similarArtist('周杰伦', '周杰伦'), isTrue);
      // 候选含多位歌手，其中一位对上即可
      expect(similarArtist('周杰伦、杨瑞代', '周杰伦'), isTrue);
      // 大小写与空格归一化
      expect(similarArtist('Jay Chou', 'jay chou'), isTrue);
      // 不同歌手不通过
      expect(similarArtist('王力宏', '周杰伦'), isFalse);
      // 原曲歌手未知/群星：不再过滤
      expect(similarArtist('随便谁', '未知歌手'), isTrue);
      expect(similarArtist('随便谁', '群星'), isTrue);
      expect(similarArtist('随便谁', ''), isTrue);
      // 候选缺歌手但原曲有：不通过
      expect(similarArtist('', '周杰伦'), isFalse);
    });

    test('durationClose：±8 秒或 15% 容差，未知时长不限制', () {
      // 任一方时长未知 → 不限制
      expect(durationClose(0, 240), isTrue);
      expect(durationClose(240, 0), isTrue);
      // 差 5 秒：通过
      expect(durationClose(245, 240), isTrue);
      // 差 10 秒、240 秒的 15%=36 → 在 15% 内通过
      expect(durationClose(250, 240), isTrue);
      // 差 30 秒（240 的 12.5%）→ 通过
      expect(durationClose(270, 240), isTrue);
      // 差 60 秒 > 36 → 不通过（超长 Live）
      expect(durationClose(300, 240), isFalse);
      // 30 秒片段 vs 240 秒正歌：不通过
      expect(durationClose(30, 240), isFalse);
    });

    test('isOddVersion：现场/伴奏/DJ/翻唱/片段等特征', () {
      expect(isOddVersion('晴天'), isFalse);
      expect(isOddVersion('Discover'), isFalse, reason: '英文词边界不误伤');
      expect(isOddVersion('Believe'), isFalse);
      expect(isOddVersion('晴天 (Live)'), isTrue);
      expect(isOddVersion('告白气球（现场版）'), isTrue);
      expect(isOddVersion('稻香 (DJ版)'), isTrue);
      expect(isOddVersion('夜曲 伴奏'), isTrue);
      expect(isOddVersion('七里香 Remix'), isTrue);
      expect(isOddVersion('测试片段'), isTrue);
      expect(isOddVersion('草原歌曲 试听'), isTrue);
    });
  });

  group('换平台提示（播放失败诊断 P1：换平台不再静默）', () {
    test('reportSourceSwitch 上报一次，UI 清除后归位；空串不上报', () {
      final service = PlayerService(initPlayer: false);
      expect(service.lastSourceSwitchNotice, isNull);
      service.reportSourceSwitch('「测试」在QQ音乐不可播，已切换网易云版本');
      expect(service.lastSourceSwitchNotice, contains('网易云版本'));
      service.clearSourceSwitchNotice();
      expect(service.lastSourceSwitchNotice, isNull);
      service.reportSourceSwitch('   ');
      expect(service.lastSourceSwitchNotice, isNull);
    });
  });

  group('QQ 用户歌单封面映射（2026-11-19 探针实测 v_playlist 驼峰字段）', () {
    test('picUrl/bigpicUrl/songNum/dirName 映射；http 升 https；旧形态兜底', () async {
      _installAdapter(_MockAdapter((o) async => _jsonBody({
            'req_0': {
              'code': 0,
              'data': {
                'v_playlist': [
                  {
                    // 「我喜欢」系统歌单：http 封面必须升 https
                    'tid': 3105161251,
                    'dirName': '我喜欢',
                    'songNum': 3,
                    'picUrl':
                        'http://y.gtimg.cn/mediastyle/y/img/cover_love_300.jpg',
                    'bigpicUrl':
                        'http://y.gtimg.cn/mediastyle/y/img/cover_love_300.jpg',
                  },
                  {
                    // 用户自建歌单：music-file 域 webp 封面
                    'tid': 8276849972,
                    'dirName': 'しんちゃん',
                    'songNum': 155,
                    'picUrl':
                        'https://music-file.y.qq.com/songlist/u/abc.webp?imageView2/4/w/600/h/600',
                  },
                  {
                    // 收藏列表 v_list 旧形态：dissname/picurl/logo/songnum
                    'tid': 123456,
                    'dissname': '旧形态歌单',
                    'songnum': 7,
                    'logo': '//y.gtimg.cn/legacy.jpg',
                  },
                ],
              },
            },
            'req_1': {
              'code': 0,
              'data': {'v_list': const []},
            },
          })));
      final api = QQMusicApi();
      api.restoreSession(const AccountSession(
        platform: JXPlatform.qq,
        cookies: {'uin': 'o935624248'},
        nickname: '用户',
      ));
      final playlists = await api.userPlaylists();
      expect(playlists.length, 3);
      // v_playlist 驼峰字段：dirName 标题、songNum 计数、picUrl 封面
      expect(playlists[0].title, '我喜欢');
      expect(playlists[0].songCount, 3);
      expect(playlists[0].coverUrl,
          'https://y.gtimg.cn/mediastyle/y/img/cover_love_300.jpg',
          reason: 'http 封面必须升 https，否则移动端明文被禁加载不出');
      expect(playlists[1].coverUrl,
          startsWith('https://music-file.y.qq.com/'));
      expect(playlists[1].songCount, 155);
      // 旧形态（dissname/logo/songnum）不回归
      expect(playlists[2].title, '旧形态歌单');
      expect(playlists[2].coverUrl, 'https://y.gtimg.cn/legacy.jpg',
          reason: '协议相对地址补 https');
      expect(playlists[2].songCount, 7);
    });
  });

  group('酷狗 gcid 歌单导入（m.kugou.com/songlist/gcid_XXX/ 分享链接）', () {
    test('gcid 先经歌单页映射成 specialid 再查 special/song', () async {
      final hosts = <String>[];
      _installAdapter(_MockAdapter((o) async {
        hosts.add(o.uri.host);
        if (o.uri.host == 'm.kugou.com') {
          // 歌单页 HTML 内嵌 gcid → specialid 映射
          expect(o.uri.path, '/songlist/gcid_3zivrucnzoz01f/');
          return ResponseBody.fromString(
              '<html>"specialid":2509422,"count":400</html>', 200,
              headers: {
                Headers.contentTypeHeader: ['text/html; charset=utf-8'],
              });
        }
        // special/song：必须用映射后的数字 specialid 查询（gcid 直查报参数不合法）
        expect(o.uri.queryParameters['specialid'], '2509422');
        return _jsonBody({
          'errcode': 0,
          'status': 1,
          'data': {
            'info': [
              {
                'hash': 'HASH001',
                'filename': '歌手A - 歌曲一',
                'duration': 200,
                'privilege': 0,
                'trans_param': {'union_cover': ''},
              },
              {
                'hash': 'HASH002',
                'filename': '歌手B - 歌曲二',
                'duration': 180,
                'privilege': 10,
                'trans_param': {'union_cover': ''},
              },
            ],
          },
        });
      }));
      final api = KuGouApi();
      final songs = await api.playlistSongs(const Playlist(
        id: '3zivrucnzoz01f',
        platform: JXPlatform.kugou,
        title: '',
      ));
      expect(songs.length, 2);
      expect(songs[0].id, 'HASH001');
      expect(songs[0].artist, '歌手A');
      expect(songs[0].title, '歌手A - 歌曲一');
      expect(songs[1].vip, isTrue);
      expect(hosts, containsAll(['m.kugou.com', 'mobiles.kugou.com']));
    });

    test('gcid 歌单页无 specialid（无效链接）：返回空列表不抛异常', () async {
      _installAdapter(_MockAdapter((o) async => ResponseBody.fromString(
          '<html>404 not found</html>', 200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          })));
      final api = KuGouApi();
      final songs = await api.playlistSongs(const Playlist(
        id: 'deadbeefxyz',
        platform: JXPlatform.kugou,
        title: '',
      ));
      expect(songs, isEmpty);
    });
  });

  group('导入歌单源元数据 playlistInfo（分享链接只有 id 的场景）', () {
    test('QQ：uniform_get_Dissinfo → dirinfo.title/picurl + total_song_num',
        () async {
      _installAdapter(_MockAdapter((o) async {
        expect(o.uri.host, 'u.y.qq.com');
        return _jsonBody({
          'playlist': {
            'code': 0,
            'data': {
              'total_song_num': 155,
              'dirinfo': {
                'id': 8276849972,
                'title': 'しんちゃん',
                'picurl':
                    'https://music-file.y.qq.com/songlist/u/abc.webp?imageView2/4/w/600/h/600',
              },
              'songlist': const [],
            },
          },
        });
      }));
      final info = await QQMusicApi().playlistInfo(const Playlist(
          id: '8276849972', platform: JXPlatform.qq, title: ''));
      expect(info, isNotNull);
      expect(info!.title, 'しんちゃん');
      expect(info.coverUrl, startsWith('https://music-file.y.qq.com/'));
      expect(info.songCount, 155);
    });

    test('酷狗 gcid：m.kugou.com 页面内嵌 listinfo（name/pic/count/创建者）',
        () async {
      _installAdapter(_MockAdapter((o) async {
        expect(o.uri.host, 'm.kugou.com');
        expect(o.uri.path, '/songlist/gcid_3zivrucnzoz01f/');
        return ResponseBody.fromString(
            '<html>{"listinfo":{"list_create_gid":"","global_collection_id":"",'
            '"type":0,"name":"最好听的英文歌，包你上瞌眼！",'
            '"pic":"http://c1.kgimg.com/custom/{size}/20200511/a.jpg","intro":"",'
            '"list_create_userid":1,"list_create_username":"大Ner","heat":1,'
            '"count":400,"specialid":2509422,"musiclib_tags":[]},'
            '"songs":[{"hash":"H1"}]}</html>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html; charset=utf-8'],
            });
      }));
      final info = await KuGouApi().playlistInfo(const Playlist(
          id: '3zivrucnzoz01f', platform: JXPlatform.kugou, title: ''));
      expect(info, isNotNull);
      expect(info!.title, '最好听的英文歌，包你上瞌眼！');
      expect(info.coverUrl, 'https://c1.kgimg.com/custom/240/20200511/a.jpg',
          reason: '{size} 替换 240 + http 升 https');
      expect(info.songCount, 400);
      expect(info.creator, '大Ner');
    });

    test('酷狗数字 specialid：无公开元数据接口，返回 null 走手填兜底', () async {
      _installAdapter(_MockAdapter((o) async => _jsonBody(const {})));
      final info = await KuGouApi().playlistInfo(const Playlist(
          id: '2509422', platform: JXPlatform.kugou, title: ''));
      expect(info, isNull);
    });

    test('网易云：v3/playlist/detail → name/coverImgUrl/trackCount', () async {
      _installAdapter(_MockAdapter((o) async {
        expect(o.uri.host, 'music.163.com');
        return _jsonBody({
          'playlist': {
            'name': '云音乐精选',
            'coverImgUrl': 'https://p1.music.126.net/xxx.jpg',
            'trackCount': 88,
            'tracks': const [],
          },
        });
      }));
      final info = await NeteaseApi().playlistInfo(const Playlist(
          id: '123456', platform: JXPlatform.netease, title: ''));
      expect(info, isNotNull);
      expect(info!.title, '云音乐精选');
      expect(info.coverUrl, startsWith('https://p1.music.126.net/'));
      expect(info.songCount, 88);
    });
  });
}
