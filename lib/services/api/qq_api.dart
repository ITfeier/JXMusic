import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import '../../models/song.dart';
import '../../models/playlist.dart';
import 'music_api.dart';
import 'http.dart';

/// QQ音乐接口（官方域名接口 + 官方扫码登录态；登录后按官方权益播放 VIP，不绕过付费）
class QQMusicApi implements MusicPlatformApi {
  @override
  int get platform => 0;

  static const String _search =
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp';
  static const String _musicu = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
  static const String _lyric =
      'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg';
  static const String _playlist =
      'https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg';

  String _guid = '';

  // ---- 官方扫码登录态（ptlogin2 标准流程）----
  static const String _ptqrshow = 'https://ssl.ptlogin2.qq.com/ptqrshow';
  static const String _ptqrlogin = 'https://ssl.ptlogin2.qq.com/ptqrlogin';
  static const String _wxaRedirect =
      'https://y.qq.com/portal/wxa_redirect.html';
  static const String _appid = '716027609'; // QQ音乐 Web 应用
  static const String _daid = '383';
  static const String _pt3rdAid = '100497308';
  final Map<String, String> _ptCookies = {}; // ssl.ptlogin2 域（qrsig）
  final Map<String, String> _loginCookies = {}; // y.qq.com 域（uin/skey/p_skey）
  String? _qrsig;

  static String get _u1 => Uri.encodeComponent(
      'https://y.qq.com/portal/wxa_redirect.html?login_type=1&surl=https%3A%2F%2Fy.qq.com%2F');

  String get _loginUin {
    final uin = _loginCookies['uin'] ?? '';
    return uin.startsWith('o') ? uin.substring(1) : uin;
  }

  String _cookieStr(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _collectSetCookies(Headers h, Map<String, String> into) {
    final list = h['set-cookie'];
    if (list == null) return;
    for (final item in list) {
      final seg = item.split(';').first.trim();
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      into[seg.substring(0, eq).trim()] = seg.substring(eq + 1).trim();
    }
  }

  /// ptqrtoken = hash33(qrsig)（QQ 官方算法）
  int _hash33(String s) {
    var e = 0;
    for (final c in s.codeUnits) {
      e += (e << 5) + c;
    }
    return 2147483647 & e;
  }

  String get _randomGuid {
    final r = Random();
    return List.generate(12, (_) => r.nextInt(10)).join();
  }

  @override
  Future<List<Song>> searchSongs(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final resp = await JXHttp.dio.get(_search, queryParameters: {
        'p': page,
        'n': size,
        'w': keyword,
        'format': 'json',
        'inCharset': 'utf-8',
        'outCharset': 'utf-8',
      });
      final songList =
          ((resp.data['data']?['song']?['list']) as List?) ?? const [];
      return songList.map<Song>((s) {
        final m = s as Map<String, dynamic>;
        final singers = (m['singer'] as List? ?? [])
            .map((x) => (x as Map)['name'] as String? ?? '')
            .join('、');
        // QQ 搜索接口 pay 字段为对象（{payplay:0/1}）而非 int，需兼容两种形态
        final pay = m['pay'];
        var payplay = 0;
        if (pay is Map) {
          payplay = (pay['payplay'] as int?) ?? 0;
        } else if (pay is int) {
          payplay = pay;
        }
        return Song(
          id: m['songmid'] as String? ?? '',
          platform: platform,
          title: m['songname'] as String? ?? '',
          artist: singers,
          album: m['albumname'] as String? ?? '',
          coverUrl:
              'https://y.qq.com/music/photo_new/T002R300x300M000${m['albummid']}.jpg',
          duration: (m['interval'] as int? ?? 0),
          vip: payplay > 0,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String?> getPlayUrl(Song song) async {
    if (_guid.isEmpty) _guid = _randomGuid;
    try {
      final uinNum = _loginUin;
      final req = {
        'req': {
          'module': 'CDN.SrfCdnMusicSvr',
          'method': 'GetCdnDispatch',
          'param': {
            'guid': _guid,
            'songmid': song.id,
            'songtype': 1,
          }
        },
        'req_0': {
          'module': 'vkey.GetVkeyServer',
          'method': 'CgiGetVkey',
          'param': {
            'guid': _guid,
            'songmid': [song.id],
            'songtype': [1],
            'uin': uinNum,
            'loginflag': 1,
            'platform': '20',
          }
        }
      };
      final resp = await JXHttp.dio.get(_musicu,
          queryParameters: {
            'format': 'json',
            'data': jsonEncode(req),
            'loginUin': uinNum,
            'hostUin': uinNum,
            'needNewCode': 0,
          },
          // QQ 播放 URL 解析需 Referer（y.qq.com），登录后附加 Cookie
          options: Options(headers: {
            if (_loginCookies.isNotEmpty)
              'Cookie': _cookieStr(_loginCookies),
            'Referer': 'https://y.qq.com/',
          }));
      final data = resp.data;
      final urls = data['req_0']?['data']?['midurlinfo'] as List?;
      if (urls == null || urls.isEmpty) return null;
      final u = urls.first as Map<String, dynamic>;
      final purl = u['purl'] as String?;
      if (purl == null || purl.isEmpty) return null;
      // 实测 sip 位于 req_0.data.sip（CgiGetVkey 返回），req.data.sip 仅为兜底
      var sipList = data['req_0']?['data']?['sip'];
      sipList ??= data['req']?['data']?['sip'];
      final prefix = (sipList is List && sipList.isNotEmpty)
          ? sipList.first as String?
          : null;
      if (prefix == null || prefix.isEmpty) return purl;
      return '$prefix$purl';
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> getLyrics(Song song) async {
    try {
      final resp = await JXHttp.dio.get(_lyric, queryParameters: {
        'songmid': song.id,
        'format': 'json',
        'nobase64': 1,
      });
      final lyric = resp.data['lyric'] as String?;
      return lyric ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<List<Playlist>> recommendPlaylists(
      {int page = 1, int size = 20}) async {
    // QQ 歌单发现接口需登录态，返回空（后续补充）
    return const [];
  }

  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
      {int page = 1, int size = 100}) async {
    try {
      final req = {
        'comm': {'ct': 24, 'cv': 0},
        'playlist': {
          'module': 'music.srfDissInfo.aiDissInfo',
          'method': 'uniform_get_Dissinfo',
          'param': {'disstid': int.tryParse(playlist.id) ?? 0, 'userinfo': 1}
        }
      };
      final resp = await JXHttp.dio.get(_musicu,
          queryParameters: {'format': 'json', 'data': jsonEncode(req)});
      final songList =
          resp.data['playlist']?['data']?['songlist'] as List? ?? const [];
      return songList.map<Song>((s) {
        final m = s as Map<String, dynamic>;
        final singers = (m['singer'] as List? ?? [])
            .map((x) => (x as Map)['name'] as String? ?? '')
            .join('、');
        return Song(
          id: m['mid'] as String? ?? '',
          platform: platform,
          title: m['name'] as String? ?? '',
          artist: singers,
          album: m['album']?['name'] as String? ?? '',
          coverUrl:
              'https://y.qq.com/music/photo_new/T002R300x300M000${m['album']?['mid']}.jpg',
          duration: (m['interval'] as int? ?? 0),
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async {
    // 巅峰榜·流行指数 topid=4（公开榜单接口 fcg_v8_toplist_cp，2026-10 验证可用）
    try {
      final resp = await JXHttp.dio.get(_playlist, queryParameters: {
        'topid': 4,
        'format': 'json',
        'page': page,
        'n': size,
      });
      final songList = (resp.data['songlist'] as List?) ?? const [];
      return songList.take(size).map<Song>((s) {
        final m = ((s as Map)['data'] as Map<String, dynamic>?) ?? const {};
        final singers = (m['singer'] as List? ?? [])
            .map((x) => (x as Map)['name'] as String? ?? '')
            .join('、');
        return Song(
          id: m['songmid'] as String? ?? '',
          platform: platform,
          title: m['songname'] as String? ?? '',
          artist: singers,
          album: m['albumname'] as String? ?? '',
          coverUrl:
              'https://y.qq.com/music/photo_new/T002R300x300M000${m['albummid']}.jpg',
          duration: (m['interval'] as int? ?? 0),
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  void restoreSession(AccountSession? session) {
    _loginCookies
      ..clear()
      ..addAll(session?.cookies ?? const <String, String>{});
    _ptCookies.clear();
    _qrsig = null;
    if (_loginCookies.isNotEmpty) _guid = _randomGuid;
  }

  // ---- 官方扫码登录（ptlogin2 标准流程：ptqrshow 取二维码 + ptqrlogin 轮询）----
  @override
  Future<({String qrUrl, String key})> createQrLogin() async {
    _ptCookies.clear();
    _loginCookies.clear();
    _qrsig = null;
    final t = DateTime.now().millisecondsSinceEpoch.toString();
    try {
      final resp = await JXHttp.dio.get(_ptqrshow,
          queryParameters: {
            'appid': _appid,
            'e': '2',
            'l': 'M',
            's': '3',
            'd': '72',
            'v': '4',
            't': t,
            'daid': _daid,
            'pt_3rd_aid': _pt3rdAid,
            'u1': _u1,
            'pt_fido_link': 1,
          },
          options: Options(responseType: ResponseType.bytes));
      _collectSetCookies(resp.headers, _ptCookies);
      _qrsig = _ptCookies['qrsig'];
      if (_qrsig == null || _qrsig!.isEmpty) {
        return (qrUrl: '', key: '');
      }
      final b64 = base64Encode(resp.data as List<int>);
      return (qrUrl: 'data:image/jpeg;base64,$b64', key: _qrsig!);
    } catch (_) {
      return (qrUrl: '', key: '');
    }
  }

  @override
  Future<AccountSession?> pollQrLogin(String key) async {
    if (_qrsig == null || _qrsig != key) return null;
    final token = _hash33(_qrsig!);
    try {
      final resp = await JXHttp.dio.get(_ptqrlogin,
          queryParameters: {
            'ptqrtoken': token,
            'webqq_type': 10,
            'remember_uin': 1,
            'login2qq': 1,
            'aid': _appid,
            'u1': _u1,
            'pt_3rd_aid': _pt3rdAid,
            'pt_fido_link': 1,
            'ptlang': 2052,
            'ptredirect': 0,
            'daid': _daid,
            'j_later': 0,
            'low_login_hour': 0,
            'regmaster': 0,
            'pt_login_type': 1,
            'pt_aid': _appid,
            'pt_aaid': 0,
            'pt_light': 0,
            'dummy': 1,
            'type': 1,
          },
          options: Options(
            headers: {'Cookie': _cookieStr(_ptCookies)},
          ));
      final text = resp.data.toString();
      // ptuiCB('0','0','跳转URL','0','登录成功!','昵称')
      final m = RegExp(
              r"ptuiCB\('(\d+)','\d+','([^']*)','\d+','([^']*)','([^']*)'")
          .firstMatch(text);
      if (m == null) return null;
      final code = m.group(1);
      if (code != '0') return null; // 66 等待扫码 / 67 待确认 / 65 过期
      final jumpUrl = m.group(2) ?? '';
      final nickname = (m.group(4) ?? '').trim();
      // 用跳转 URL 中的 qqmusic_key 换取 y.qq.com 域登录 cookie（uin/skey/p_skey）
      _loginCookies.clear();
      final keyMatch = RegExp(r'qqmusic_key=([^&]+)').firstMatch(jumpUrl);
      if (keyMatch != null) {
        await _exchangeKey(keyMatch.group(1)!);
      }
      if (_loginCookies.isEmpty) return null;
      return AccountSession(
        platform: platform,
        cookies: Map.of(_loginCookies),
        nickname: nickname.isEmpty ? 'QQ用户' : nickname,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _exchangeKey(String qqmusicKey) async {
    try {
      final resp = await JXHttp.dio.get(_wxaRedirect,
          queryParameters: {
            'login_type': 1,
            'surl': 'https://y.qq.com/',
            'qqmusic_key': qqmusicKey,
          },
          options: Options(
            followRedirects: false,
            validateStatus: (s) => s != null && s < 500,
          ));
      _collectSetCookies(resp.headers, _loginCookies);
    } catch (_) {
      // 换 cookie 失败视为登录未完成
    }
  }
}
