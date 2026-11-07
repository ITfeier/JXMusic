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

  // ---- 官方扫码登录态（ptlogin2 + QQ Connect 标准流程，2026-11 实测口径）----
  // 链路：ptqrshow 取码 → ptqrlogin 轮询 → 扫码确认后 check_sig 换 p_skey →
  // graph.qq.com/oauth2.0/authorize 换 code → musicu QQConnectLogin.LoginServer.QQLogin
  // 换 musicid/musickey（写入 uin/qqmusic_uin/qm_keyst/qqmusic_key cookie）。
  //
  // 与旧实现的关键差异（2026-11-08 本机实测，历经 QA 独立复核）：
  // 1) ptqrshow 的关键变量是 **u1**：带 u1（无论指向 y.qq.com 还是 graph，任何编码形态）
  //    会被网关（TAPISIX）以 403 拒绝；不带 u1 时 200 + 真二维码 PNG（111x111）+ qrsig(128)。
  //    注意：真二维码 PNG 压缩后仅约 430~450 字节，与"占位图"大小接近，不能按字节数判断真伪。
  // 2) ptqrlogin 必须带 u1=graph.qq.com/oauth2.0/login_jump，且要带齐 action/js_ver 等
  //    浏览器侧参数：缺 u1 → ptuiCB('7',...,'提交参数错误')；u1 指向 y.qq.com 旧地址 → 403。
  // 3) 旧 y.qq.com/portal/wxa_redirect.html 已 404，qqmusic_key 换 cookie 链路失效，
  //    改为 check_sig → authorize → QQLogin 取 musicid/musickey。
  static const String _ptqrshow = 'https://ssl.ptlogin2.qq.com/ptqrshow';
  static const String _ptqrlogin = 'https://ssl.ptlogin2.qq.com/ptqrlogin';
  static const String _checkSig = 'https://ssl.ptlogin2.graph.qq.com/check_sig';
  static const String _qqAuthorize = 'https://graph.qq.com/oauth2.0/authorize';
  static const String _loginJump = 'https://graph.qq.com/oauth2.0/login_jump';
  static const String _redirectUri =
      'https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/';
  static const String _appid = '716027609'; // QQ音乐 Web 应用
  static const String _daid = '383';
  static const String _pt3rdAid = '100497308';
  final Map<String, String> _ptCookies = {}; // ssl.ptlogin2 域（qrsig）
  final Map<String, String> _loginCookies = {}; // y.qq.com 域（uin/musickey）
  String? _qrsig;

  /// 最近一次扫码操作失败原因（成功/等待时为 null，供设置页展示准确提示）
  String? _lastError;

  @override
  String? get lastError => _lastError;

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

  /// hash33（QQ 官方算法）：h = (h << 5) + h + c，返回低 31 位
  /// - ptqrtoken = hash33(qrsig)
  /// - g_tk = hash33(p_skey, 5381)
  int _hash33(String s, [int h = 0]) {
    var e = h;
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

  // ---- 官方扫码登录（ptqrshow 取码 + ptqrlogin 轮询 + QQ Connect 换登录态）----
  @override
  Future<({String qrUrl, String key})> createQrLogin() async {
    _ptCookies.clear();
    _loginCookies.clear();
    _qrsig = null;
    _lastError = null;
    try {
      final resp = await JXHttp.dio.get(_ptqrshow,
          queryParameters: {
            'appid': _appid,
            'e': '2',
            'l': 'M',
            's': '3',
            'd': '72',
            'v': '4',
            't': DateTime.now().millisecondsSinceEpoch.toString(),
            'daid': _daid,
            'pt_3rd_aid': _pt3rdAid,
            // 不要加 u1：u1 与 daid 同时出现会被网关 403（2026-11 实测）
          },
          options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 10),
            headers: {'Referer': 'https://xui.ptlogin2.qq.com/'},
          ));
      _collectSetCookies(resp.headers, _ptCookies);
      final qrsig = _ptCookies['qrsig'] ?? '';
      final bytes =
          resp.data is List<int> ? resp.data as List<int> : const <int>[];
      // 真二维码判据：PNG 魔数 + 111x111（压缩后仅约 400~500 字节，但不能按字节数判断）
      if (qrsig.length <= 40 || !_isQrPng(bytes)) {
        _lastError = 'QQ 取码返回异常图片（可能被网关风控），请更换网络后重试';
        return (qrUrl: '', key: '');
      }
      _qrsig = qrsig;
      return (qrUrl: 'data:image/png;base64,${base64Encode(bytes)}', key: qrsig);
    } catch (e) {
      _lastError = _describeError(e, 'QQ 二维码获取失败');
      return (qrUrl: '', key: '');
    }
  }

  /// 把网络异常翻译成用户能看懂的原因
  String _describeError(Object error, String prefix) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 403) {
        return '$prefix：请求被 QQ 服务器拒绝（403，通常是网络风控），请更换网络后重试';
      }
      if (code != null) return '$prefix：HTTP $code';
      return '$prefix：网络不可达（${error.type.name}）';
    }
    return '$prefix：$error';
  }

  /// 校验响应确实是二维码 PNG（魔数 8950 4E47 + IHDR 宽高 >= 80，排除占位/错误图）
  bool _isQrPng(List<int> bytes) {
    if (bytes.length < 33) return false;
    const magic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    final w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    return w >= 80 && h >= 80;
  }

  @override
  Future<AccountSession?> pollQrLogin(String key) async {
    if (_qrsig == null || _qrsig != key || key.isEmpty) return null;
    try {
      final resp = await JXHttp.dio.get(_ptqrlogin,
          queryParameters: {
            // 必须带 u1=graph.qq.com/oauth2.0/login_jump：缺 u1 → code 7 参数错误，
            // 指向 y.qq.com 旧地址（wxa_redirect.html 已 404）→ 网关 403
            'u1': _loginJump,
            'ptqrtoken': _hash33(key).toString(),
            'ptredirect': '0',
            'h': '1',
            't': '1',
            'g': '1',
            'from_ui': '1',
            'ptlang': '2052',
            'action': '0-0-${DateTime.now().millisecondsSinceEpoch}',
            'js_ver': '20102616',
            'js_type': '1',
            'pt_uistyle': '40',
            'aid': _appid,
            'daid': _daid,
            'pt_3rd_aid': _pt3rdAid,
            'has_onekey': '1',
          },
          options: Options(headers: {
            'Referer': 'https://xui.ptlogin2.qq.com/',
            'Cookie': 'qrsig=$key',
          }));
      final text = resp.data.toString();
      // ptuiCB('0','0','跳转URL','0','登录成功!','昵称')
      // 66=未扫码 67=待确认 65=已过期
      final m = RegExp(
              r"ptuiCB\('(\d+)','\d+','([^']*)','\d+','([^']*)','([^']*)'")
          .firstMatch(text);
      if (m == null) {
        _lastError = 'QQ 轮询返回异常内容，登录接口可能已变更';
        return null;
      }
      final code = m.group(1) ?? '';
      if (code == '66' || code == '67') {
        _lastError = null; // 等待扫码 / 待确认，属正常状态
        return null;
      }
      if (code == '65') {
        _lastError = '二维码已过期，请关闭后重新获取';
        return null;
      }
      if (code == '7') {
        _lastError = 'QQ 轮询参数校验失败，登录接口可能已变更';
        return null;
      }
      if (code != '0') {
        _lastError = 'QQ 登录未完成（code $code）';
        return null;
      }
      final jumpUrl = m.group(2) ?? '';
      final ptNick = (m.group(4) ?? '').trim();
      final uin = RegExp(r'[?&]uin=([^&]+)').firstMatch(jumpUrl)?.group(1) ?? '';
      final sigx =
          RegExp(r'[?&]ptsigx=([^&]+)').firstMatch(jumpUrl)?.group(1) ?? '';
      if (uin.isEmpty || sigx.isEmpty) {
        _lastError = 'QQ 登录跳转参数解析失败（接口可能已变更）';
        return null;
      }

      final data = await _exchangeLogin(uin, sigx);
      if (data == null) {
        _lastError = 'QQ 扫码已确认，但换取登录态失败（check_sig/authorize/QQLogin）';
        return null;
      }
      final rawId = data['musicid'];
      final musicid = (rawId is num && rawId > 0)
          ? '${rawId.toInt()}'
          : '${data['str_musicid'] ?? ''}'.replaceFirst(RegExp('^[oO]'), '');
      final musickey = '${data['musickey'] ?? ''}';
      if (musicid.isEmpty || musicid == '0' || musickey.isEmpty) {
        _lastError = 'QQ 登录凭证不完整（缺少 musicid/musickey）';
        return null;
      }

      var nick = '${data['nick'] ?? ''}'.trim();
      if (nick.isEmpty) nick = ptNick;
      if (nick.isEmpty) nick = 'QQ用户';

      _loginCookies
        ..clear()
        ..['uin'] = musicid
        ..['qqmusic_uin'] = musicid
        ..['qm_keyst'] = musickey
        ..['qqmusic_key'] = musickey;
      _guid = _randomGuid;
      _lastError = null;
      return AccountSession(
        platform: platform,
        cookies: Map.of(_loginCookies),
        nickname: nick,
      );
    } catch (e) {
      _lastError = _describeError(e, 'QQ 扫码轮询失败');
      return null;
    }
  }

  /// 扫码确认后换登录态：check_sig 取 p_skey → oauth2/authorize 取 code →
  /// musicu `QQConnectLogin.LoginServer.QQLogin` 取 musicid/musickey。
  /// 任一步失败返回 null（视为登录未完成，不抛异常）。
  Future<Map<String, dynamic>?> _exchangeLogin(
      String uin, String ptsigx) async {
    try {
      final sigResp = await JXHttp.dio.get(_checkSig,
          queryParameters: {
            'uin': uin,
            'pttype': '1',
            'service': 'ptqrlogin',
            'nodirect': '0',
            'ptsigx': ptsigx,
            's_url': _loginJump,
            'ptlang': '2052',
            'ptredirect': '100',
            'aid': _appid,
            'daid': _daid,
            'j_later': '0',
            'low_login_hour': '0',
            'regmaster': '0',
            'pt_login_type': '3',
            'pt_aid': '0',
            'pt_aaid': '16',
            'pt_light': '0',
            'pt_3rd_aid': _pt3rdAid,
          },
          options: Options(
            followRedirects: false,
            validateStatus: (s) => s != null && s < 500,
            headers: {'Referer': 'https://xui.ptlogin2.qq.com/'},
          ));
      final ptCookies = <String, String>{};
      _collectSetCookies(sigResp.headers, ptCookies);
      final pSkey = ptCookies['p_skey'] ?? '';
      if (pSkey.isEmpty) return null;

      final authResp = await JXHttp.dio.post(_qqAuthorize,
          data: {
            'response_type': 'code',
            'client_id': _pt3rdAid,
            'redirect_uri': _redirectUri,
            'scope': 'get_user_info,get_app_friends',
            'state': 'state',
            'switch': '',
            'from_ptlogin': '1',
            'src': '1',
            'update_auth': '1',
            'openapi': '1010_1030',
            'g_tk': _hash33(pSkey, 5381).toString(),
            'auth_time': DateTime.now().millisecondsSinceEpoch.toString(),
            'ui': _uuidV4,
          },
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            followRedirects: false,
            validateStatus: (s) => s != null && s < 500,
            headers: {
              'Referer': 'https://graph.qq.com/',
              'Cookie': _cookieStr(ptCookies),
            },
          ));
      var code = '';
      final location = authResp.headers.value('Location') ??
          authResp.headers.value('location') ??
          '';
      code = RegExp(r'[?&]code=([^&]+)').firstMatch(location)?.group(1) ?? '';
      if (code.isEmpty) {
        // 部分情况下 302 的 Location 丢失，兜底从响应体/跳转脚本里取 code
        code = RegExp(r'(?:[?&]|\\u0026)code=([^&"\\\s]+)')
                .firstMatch('${authResp.data}')
                ?.group(1) ??
            '';
      }
      if (code.isEmpty) return null;

      final loginResp = await JXHttp.dio.get(_musicu,
          queryParameters: {
            'format': 'json',
            'data': jsonEncode({
              'comm': {
                'ct': 24,
                'cv': 4747474,
                'platform': 'yqq.json',
                'format': 'json',
                'inCharset': 'utf-8',
                'outCharset': 'utf-8',
                'notice': 0,
                'need_new_code': 1,
                'tmeLoginType': 2,
              },
              'req': {
                'module': 'QQConnectLogin.LoginServer',
                'method': 'QQLogin',
                'param': {'code': code},
              }
            }),
          },
          options: Options(headers: {'Referer': 'https://y.qq.com/'}));
      final raw = loginResp.data;
      if (raw is! Map) return null;
      final req = raw['req'];
      if (req is! Map) return null;
      final data = req['data'];
      if (data is! Map) return null;
      return Map<String, dynamic>.from(data);
    } catch (_) {
      return null;
    }
  }

  /// 简易 UUID v4（authorize 的 ui 参数，无强校验）
  String get _uuidV4 {
    final r = Random();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-'
        '${(8 + r.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }
}
