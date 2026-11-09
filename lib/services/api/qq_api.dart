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
  /// 歌单广场（最热歌单）：categoryId=10000000 全部、sortId=5 最热
  static const String _dissByTag =
      'https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg';

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
  // 4) 兑换链路（check_sig/authorize/QQLogin）尚未真机扫码端到端验证，故做成
  //    候选列表 + 降级/重试，每步失败写 _lastError；接口变化时只改下面配置区。
  //
  // ---- 登录接口配置区（来源：L-1124/QQMusicApi 参考实现 + 2026-11 本机实测抓包）----
  // 取码/轮询：已实测可用（200 + 真二维码 / ptuiCB code 66），参数不要随意改。
  static const String _ptqrshow = 'https://ssl.ptlogin2.qq.com/ptqrshow';
  static const String _ptqrlogin = 'https://ssl.ptlogin2.qq.com/ptqrlogin';
  static const String _loginJump = 'https://graph.qq.com/oauth2.0/login_jump';
  // authorize 的 redirect_uri：2026 现行参考实现用**双重编码**形式
  // （surl=https%3A%252F%252Fy.qq.com%252F），旧实现是明文形式；
  // 两种都试，谁先拿到 code 用谁（实扫失败后按监国要求补充双重编码候选）。
  static const List<String> _authorizeRedirectUris = <String>[
    'https://y.qq.com/portal/wx_redirect.html?login_type=1'
        '&surl=https%3A%252F%252Fy.qq.com%252F',
    'https://y.qq.com/portal/wx_redirect.html?login_type=1'
        '&surl=https://y.qq.com/',
  ];

  // 兑换链路候选：主用第一个，失败按顺序切下一个；接口失效时只改这里。
  // check_sig：扫码确认后换 p_skey（参考实现同域名，2026-11 实测 302 可达）
  static const List<String> _checkSigCandidates = <String>[
    'https://ssl.ptlogin2.graph.qq.com/check_sig',
  ];
  // authorize：QQ 互联 OAuth 授权码（参考实现同域名，2026-11 实测 302 可达）
  static const List<String> _authorizeCandidates = <String>[
    'https://graph.qq.com/oauth2.0/authorize',
  ];
  // QQLogin：音乐网关换 musicid/musickey
  //  · u.y.qq.com/cgi-bin/musicu.fcg   主：实测返回 QQLogin 业务响应（fake code → code=1000）
  //  · u6.y.qq.com/cgi-bin/musicu.fcg  备1：同构镜像，实测同样返回 QQLogin 业务响应
  //  · u.y.qq.com/cgi-bin/musics.fcg   备2：当前需 zzc sign（外层 code=2000），保留待签名方案
  static const List<String> _qqLoginCandidates = <String>[
    'https://u.y.qq.com/cgi-bin/musicu.fcg',
    'https://u6.y.qq.com/cgi-bin/musicu.fcg',
    'https://u.y.qq.com/cgi-bin/musics.fcg',
  ];
  static const String _appid = '716027609'; // QQ音乐 Web 应用
  static const String _daid = '383';
  static const String _pt3rdAid = '100497308';
  /// 扫码确认后「check_sig + OAuth 链 / authorize + QQLogin」整条兑换链的总超时。
  /// 实扫证据（2026-11-09）显示 check_sig 会 302 到 graph.qq.com/oauth2.0/login_jump，
  /// 需要继续跟随 OAuth 跳转链取 code，故总预算放宽到 30s。
  static const Duration _exchangeTimeout = Duration(seconds: 30);

  final Map<String, String> _ptCookies = {}; // ssl.ptlogin2 域（qrsig）
  final Map<String, String> _loginCookies = {}; // y.qq.com 域（uin/musickey）
  String? _qrsig;

  /// 最近一次扫码操作失败原因（成功/等待时为 null，供设置页展示准确提示）
  String? _lastError;

  /// 本次二维码是否已在服务端确认（ptuiCB code=0）。
  /// 设置页据此在"已确认但兑换失败"时停止轮询，避免同一二维码每 2 秒被重复兑换。
  bool _scanConfirmed = false;

  bool get qrScanConfirmed => _scanConfirmed;

  @override
  String? get lastError => _lastError;

  String get _loginUin {
    final uin = _loginCookies['uin'] ?? '';
    return uin.startsWith('o') ? uin.substring(1) : uin;
  }

  String _cookieStr(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// 合并响应头 Set-Cookie 到 cookie jar。
  ///
  /// **必须忽略值为空的 Set-Cookie**：2026-11-09 实扫取证显示 check_sig 的 302
  /// 会先下发有效 `p_skey`（44 字符），随后又下发同名清空行 `p_skey=` 用于删除
  /// 父域/其它 Path 上的旧 cookie；若按 last-wins 覆盖，jar 里 p_skey 会变空，
  /// authorize 的 g_tk 退化为 hash33('')=5381，导致拿不到授权 code。
  void _collectSetCookies(Headers h, Map<String, String> into) {
    final list = h['set-cookie'];
    if (list == null) return;
    for (final item in list) {
      final seg = item.split(';').first.trim();
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final name = seg.substring(0, eq).trim();
      final value = seg.substring(eq + 1).trim();
      // 空值 = 删除 cookie 的指令（服务端用同名空 cookie 清父域），
      // 不能覆盖已拿到的有效值。
      if (name.isEmpty || value.isEmpty) continue;
      into[name] = value;
    }
  }

  /// 大小写不敏感地取响应头（dio 的 header map 通常已小写，这里再兜一层）
  String _headerValue(Headers h, String name) {
    final v = h.value(name);
    if (v != null && v.isNotEmpty) return v;
    final target = name.toLowerCase();
    for (final e in h.map.entries) {
      if (e.key.toLowerCase() == target && e.value.isNotEmpty) {
        return e.value.first;
      }
    }
    return '';
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

  // ---- 扫码链路诊断日志（2026-11 实扫排查用）----
  // 日志走 print：Android 上 `adb logcat -s flutter` 可见；不引入 Flutter 依赖，
  // 保证 `dart run tool/check_qq_qr.dart` 仍能执行。日志里不输出完整 cookie/token。
  void _log(String message) {
    // ignore: avoid_print
    print('[JXMusic][QQ登录] $message');
  }

  /// 打码：只保留前 [head] 后 [tail] 个字符；短值只输出长度
  static String _mask(String? value, {int head = 4, int tail = 4}) {
    if (value == null || value.isEmpty) return '(空)';
    if (value.length <= head + tail) return 'len=${value.length}';
    return '${value.substring(0, head)}…${value.substring(value.length - tail)}'
        '(len=${value.length})';
  }

  static String _short(Object? value, [int max = 160]) {
    final s = '${value ?? ''}';
    return s.length <= max ? s : '${s.substring(0, max)}…(len=${s.length})';
  }

  /// URL 参数名保留、参数值打码后输出（用于观察 ptuiCB 跳转 URL 结构而不泄露 uin/ptsigx）
  static String _maskUrl(String? url) {
    if (url == null || url.isEmpty) return '(空)';
    final uri = Uri.tryParse(url);
    if (uri == null) return '(不可解析)';
    final parts = <String>[];
    uri.queryParametersAll.forEach((k, vals) {
      parts.add('$k=${vals.isEmpty ? '' : _mask(vals.first)}');
    });
    return '${uri.host}${uri.path}?${parts.join('&')}';
  }

  /// 无重定向 GET：check_sig / authorize 的 p_skey / code 在 302 的响应头里，
  /// 必须关掉自动跟随才能逐跳收集 Set-Cookie（Dio 自动跟随会丢中间 Set-Cookie）。
  Future<Response<dynamic>> _getRaw(String url,
      {Map<String, dynamic>? query, Map<String, String>? headers}) {
    return JXHttp.dio.get(url,
        queryParameters: query,
        options: Options(
          followRedirects: false,
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 10),
          headers: {'Referer': 'https://xui.ptlogin2.qq.com/', ...?headers},
        ));
  }

  @override
  Future<List<Song>> searchSongs(String keyword,
      {int page = 1, int size = 30}) async {
    // QQ 搜索接口单页最多约 60 条（n=100 会返回空），因此大请求量在内部按页累加，
    // 保证「搜索 100 首」时 QQ 也能贡献完整结果。
    const maxPerPage = 50;
    final out = <Song>[];
    var currentPage = page;
    try {
      while (out.length < size) {
        final want = (size - out.length).clamp(1, maxPerPage);
        final batch = await _searchPage(keyword, currentPage, want);
        if (batch.isEmpty) break;
        out.addAll(batch);
        if (batch.length < want) break;
        currentPage++;
        if (currentPage - page > 10) break; // 安全上限，避免无限翻页
      }
      return out.take(size).toList();
    } catch (_) {
      return out;
    }
  }

  /// 单页 QQ 搜索（n 建议 <= 60）
  Future<List<Song>> _searchPage(String keyword, int page, int size) async {
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

  /// 构造「歌单广场」请求 URI（单独抽出便于单测）。
  ///
  /// **不要删掉 inCharset/outCharset=utf-8**：该接口默认按 GB2312/GBK 返回
  /// （响应头 `Content-Type: application/x-javascript;charset=gb2312`），
  /// Dio 按 UTF-8 解码会把中文歌单标题解成 `�` 替换字符（0.9.7 首页乱码）。
  /// 显式要求 UTF-8 后服务端改回 `charset=utf-8`，中文正常（2026-11 实测）。
  static Uri dissByTagUri({required int page, required int size, int? rnd}) {
    final start = (page - 1) * size;
    return Uri.parse(_dissByTag).replace(queryParameters: {
      'categoryId': '10000000',
      'sortId': '5',
      'sin': '$start',
      'ein': '${start + size - 1}',
      'format': 'json',
      'rnd': '${rnd ?? DateTime.now().millisecondsSinceEpoch}',
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
    });
  }

  @override
  Future<List<Playlist>> recommendPlaylists(
      {int page = 1, int size = 20}) async {
    // 歌单广场（按最热排序）：categoryId=10000000 全部、sortId=5 最热。
    // 2026-11 实测公开可用，无需登录。参数与 GBK 乱码修复见 [dissByTagUri]。
    try {
      final resp = await JXHttp.dio.getUri(
          dissByTagUri(page: page, size: size),
          options: Options(headers: {'Referer': 'https://y.qq.com/'}));
      final raw = resp.data;
      final dataMap = raw is Map ? raw['data'] : null;
      final list =
          (dataMap is Map ? dataMap['list'] as List? : null) ?? const [];
      return list.map<Playlist>((raw) {
        final m = raw as Map;
        final creator = m['creator'] as Map?;
        return Playlist(
          id: '${m['dissid'] ?? ''}',
          platform: platform,
          title: (m['dissname'] as String? ?? '').trim(),
          coverUrl: jxNormalizeImageUrl(m['imgurl'] as String?),
          creator: creator?['name'] as String? ?? '',
          songCount: 0,
        );
      }).where((p) => p.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
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
      // 必须带 QQ 音乐域名 Referer：JXHttp 全局默认 Referer=https://music.163.com/，
      // 被 QQ musicu 接口识别为站外来源后返回空 songlist（total_song_num=0），
      // 真机表现为歌单详情「0 首 + 列表空白」。同一 disstid 实测：
      // 默认 Referer→0 首；Referer=https://y.qq.com/ → 66 首。
      final resp = await JXHttp.dio.get(_musicu,
          queryParameters: {'format': 'json', 'data': jsonEncode(req)},
          options: Options(headers: {'Referer': 'https://y.qq.com/'}));
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
    _scanConfirmed = false;
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
      _log('取码 HTTP=${resp.statusCode} qrsig=${_mask(qrsig)} '
          'PNG=${bytes.length}字节 '
          'set-cookie=[${_ptCookies.keys.join(',')}]');
      // 真二维码判据：PNG 魔数 + 111x111（压缩后仅约 400~500 字节，但不能按字节数判断）
      if (qrsig.length <= 40 || !_isQrPng(bytes)) {
        _lastError = 'QQ 取码返回异常图片（可能被网关风控），请更换网络后重试';
        _log(_lastError!);
        return (qrUrl: '', key: '');
      }
      _qrsig = qrsig;
      return (qrUrl: 'data:image/png;base64,${base64Encode(bytes)}', key: qrsig);
    } catch (e) {
      _lastError = _describeError(e, 'QQ 二维码获取失败');
      _log('取码异常：$_lastError');
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
      final cb = parsePtuiCb(text);
      if (cb == null) {
        // 隐私（QA D-01）：不打印原始响应（可能含 uin/ptsigx/昵称），只留长度
        _log('轮询响应无法解析：len=${text.length}');
        _lastError = 'QQ 轮询返回异常内容，登录接口可能已变更';
        return null;
      }
      final code = cb.code;
      if (code == '66' || code == '67') {
        _log('轮询 code=$code（等待扫码/待确认）');
        _lastError = null; // 等待扫码 / 待确认，属正常状态
        return null;
      }
      if (code == '65') {
        _log('轮询 code=65（二维码已过期）');
        _lastError = '二维码已过期，请关闭后重新获取';
        return null;
      }
      if (code == '7') {
        _log('轮询 code=7 msg=${_short(cb.message)}');
        _lastError = cb.message.trim().isEmpty
            ? 'QQ 轮询参数校验失败，登录接口可能已变更'
            : 'QQ 轮询参数校验失败：${cb.message.trim()}';
        return null;
      }
      if (code != '0') {
        _log('轮询 code=$code msg=${_short(cb.message)}');
        _lastError = 'QQ 登录未完成（code $code）';
        return null;
      }
      // 服务端已确认扫码（code=0）：标记后即使后续兑换失败，设置页也停止轮询，
      // 避免同一个二维码被 2 秒定时器反复兑换（实扫观测到连续兑换 5+ 次）。
      _scanConfirmed = true;
      // 服务端返回的跳转 URL 里已带 uin/ptsigx 及签名参数；HTML 转义（&amp;）需还原
      final jumpUrl = cb.redirectUrl.replaceAll('&amp;', '&');
      final ptNick = cb.nickname.trim();
      final parsedJump = Uri.tryParse(jumpUrl);
      var uin = parsedJump?.queryParameters['uin'] ?? '';
      var sigx = parsedJump?.queryParameters['ptsigx'] ?? '';
      if (uin.isEmpty) {
        uin = RegExp(r'[?&]uin=([^&]+)').firstMatch(jumpUrl)?.group(1) ?? '';
      }
      if (sigx.isEmpty) {
        sigx = RegExp(r'[?&]ptsigx=([^&]+)').firstMatch(jumpUrl)?.group(1) ?? '';
      }
      _log('轮询 code=0 扫码确认；跳转URL=${_maskUrl(jumpUrl)} '
          'uin=${_mask(uin)} ptsigx=${_mask(sigx)} '
          '昵称=${ptNick.isEmpty ? '(空)' : ptNick}');
      if (sigx.isEmpty) {
        _lastError = 'QQ 登录跳转参数解析失败：缺少 ptsigx（接口可能已变更）';
        return null;
      }
      if (uin.isEmpty) {
        // 第三方应用可能隐藏 QQ 号，此时仍可用服务端 URL 里的其它参数尝试 check_sig
        _log('警告：跳转 URL 未携带 uin，继续用服务端 URL 尝试 check_sig');
      }

      _lastError = null;
      final data = await _exchangeLogin(uin, sigx, jumpUrl).timeout(
        _exchangeTimeout,
        onTimeout: () {
          _lastError =
              'QQ 扫码已确认，但兑换登录态超时（>${_exchangeTimeout.inSeconds} 秒）';
          _log(_lastError!);
          return null;
        },
      );
      if (data == null) {
        // 优先保留 _exchangeLogin 里更具体的原因（check_sig/authorize/QQLogin）
        _lastError ??= 'QQ 扫码已确认，但换取登录态失败（check_sig/authorize/QQLogin）';
        return null;
      }
      final rawId = data['musicid'];
      final musicid = (rawId is num && rawId > 0)
          ? '${rawId.toInt()}'
          : '${data['str_musicid'] ?? ''}'.replaceFirst(RegExp('^[oO]'), '');
      final musickey = '${data['musickey'] ?? ''}';
      if (musicid.isEmpty || musicid == '0' || musickey.isEmpty) {
        _lastError = 'QQ 登录凭证不完整（缺少 musicid/musickey）';
        _log('登录凭证不完整：musicid=${_mask(musicid)} musickey=${_mask(musickey)}');
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
      _log('登录成功：昵称=$nick musicid=${_mask(musicid)} '
          'musickey=${_mask(musickey)} '
          '写入 cookie=[${_loginCookies.keys.join(',')}]');
      return AccountSession(
        platform: platform,
        cookies: Map.of(_loginCookies),
        nickname: nick,
      );
    } catch (e) {
      _lastError = _describeError(e, 'QQ 扫码轮询失败');
      _log('轮询异常：$_lastError');
      return null;
    }
  }

  // ---- 兑换链路私有参数（集中于此，便于对照抓包/参考实现排查）----
  /// check_sig 参数（来源：L-1124/QQMusicApi `_authorize_qq_qr`）
  Map<String, dynamic> _checkSigParams(String uin, String ptsigx) => {
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
      };

  /// authorize 参数（来源：同上；g_tk = hash33(p_skey, 5381)）
  Map<String, String> _authorizeParams(String pSkey, String redirectUri) => {
        'response_type': 'code',
        'client_id': _pt3rdAid,
        'redirect_uri': redirectUri,
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
      };

  /// QQLogin 请求体（comm 取 Web 版：ct=24 / cv=4747474 / platform=yqq.json）
  Map<String, dynamic> _qqLoginPayload(String code) => {
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
        },
      };

  /// 单次 check_sig 尝试：GET（不自动跟随）→ 合并 Set-Cookie。
  /// 返回首个响应的可读摘要与首个 Location（供后续 OAuth 链复用）。
  ///
  /// 取证（2026-11-09 实扫定案）：Set-Cookie 原始行用 [打码 + 值长度 + 前4后4]
  /// 输出即可定位"先发有效 p_skey 再发同名空值"的问题，无需打印明文；
  /// Location / body 同样打码或只留长度（QA D-01 隐私要求）。
  Future<({String summary, String location})> _attemptCheckSig({
    required String url,
    Map<String, dynamic>? query,
    required Map<String, String> jar,
    required String tag,
    bool sendJar = true,
  }) async {
    final summary = <String>[];
    final rawUrl =
        query == null || query.isEmpty ? url : '$url?${_queryString(query)}';
    _log('$tag 请求: ${_maskUrl(rawUrl)} len=${rawUrl.length}');
    var current = await _getRaw(url,
        query: query,
        headers: {if (sendJar && jar.isNotEmpty) 'Cookie': _cookieStr(jar)});
    var status = current.statusCode ?? 0;
    var location = _headerValue(current.headers, 'location');
    final firstLocation = location;
    _collectSetCookies(current.headers, jar);
    var hasPskey = (jar['p_skey'] ?? '').isNotEmpty;
    final bodyText = '${current.data ?? ''}';
    _log('$tag → HTTP $status location=${_maskUrl(location)} len=${location.length}');
    _log('$tag Set-Cookie原始: ${_setCookieDigest(current.headers)}');
    _log('$tag jar=[${jar.keys.join(',')}] p_skey=$hasPskey bodyLen=${bodyText.length}');
    summary.add('$tag HTTP$status'
        '${location.isEmpty ? '' : '→${_maskUrl(location)}'}'
        '${hasPskey ? ' 已拿到p_skey' : ' 无p_skey'}');
    // 注意：这里**不再自动跟随 302**。check_sig 成功时 302 指向
    // graph.qq.com/oauth2.0/login_jump，后续跳转链由 _codeFromOAuthChain 统一处理
    // （避免同一跳转链被两处各走一遍、影响一次性 code/状态）。
    return (summary: summary.join('；'), location: firstLocation);
  }

  /// 把响应头 Set-Cookie 原始行打码后输出（名字 + 值长度 + 前4后4），
  /// 用于判断服务端是否下发了空值 cookie，不泄露完整敏感值。
  String _setCookieDigest(Headers headers) {
    final list = headers['set-cookie'];
    if (list == null || list.isEmpty) return '(无)';
    final out = <String>[];
    for (final raw in list) {
      final seg = raw.split(';').first.trim();
      final eq = seg.indexOf('=');
      if (eq <= 0) {
        out.add(_short(raw, 30));
        continue;
      }
      final name = seg.substring(0, eq).trim();
      final value = seg.substring(eq + 1).trim();
      out.add('$name=${_mask(value)}');
    }
    return out.join(' | ');
  }

  /// 把查询参数按 URI 规范拼回字符串（仅用于日志打印原始 URL）
  String _queryString(Map<String, dynamic> query) => query.entries
      .map((e) => '${e.key}=${Uri.encodeQueryComponent('${e.value}')}')
      .join('&');

  /// 扫码确认后换登录态：check_sig 取 p_skey → oauth2/authorize 取 code →
  /// QQLogin 取 musicid/musickey。
  ///
  /// 2026-11 真机实扫首轮失败（"check_sig 无 p_skey"）后的加固与取证：
  /// - 参考实现（L-1124/QQMusicApi `_authorize_qq_qr`）是**不带 Cookie** 请求
  ///   `ssl.ptlogin2.graph.qq.com/check_sig`，p_skey 就在首个响应（常见为 302）
  ///   的 Set-Cookie 里 —— 先照做；
  /// - 拿不到时依次兜底：① 带 qrsig Cookie 重试（浏览器里的 check_sig 是带
  ///   ptlogin 域登录 cookie 的）；② 直接请求 ptuiCB 返回的 check_sig URL
  ///   （服务端给的 URL 带完整签名参数）；
  /// - 每次请求/每一跳都记录 status、location、Set-Cookie 名称、p_skey 是否存在
  ///   （值一律打码）；
  /// - authorize 先 POST，取不到 code 时无条件降级 GET；
  /// - QQLogin 记录外层/业务 code，业务成功才返回 data。
  Future<Map<String, dynamic>?> _exchangeLogin(
      String uin, String ptsigx, String ptuiJumpUrl) async {
    try {
      final ptCookies = <String, String>{};
      final steps = <String>[];
      final primary = _checkSigCandidates.first;
      var gotPskey = false;

      var chainStart = '';

      // 1a) 参考实现同款：不带 Cookie，直接读首个响应 Set-Cookie
      try {
        final attempt = await _attemptCheckSig(
          url: primary,
          query: _checkSigParams(uin, ptsigx),
          jar: ptCookies,
          tag: 'check_sig#1(无Cookie)',
          sendJar: false,
        );
        steps.add(attempt.summary);
        chainStart = attempt.location;
      } catch (e) {
        steps.add('check_sig#1 异常 ${_describeError(e, '')}');
        _log('check_sig#1 异常：${_describeError(e, '')}');
      }
      gotPskey = (ptCookies['p_skey'] ?? '').isNotEmpty;

      // 1b) 若 1a 既没 p_skey 也没拿到 302 入口，带 qrsig 再取一次入口
      if (!gotPskey && chainStart.isEmpty) {
        final qrsig = _qrsig;
        if (qrsig != null && qrsig.isNotEmpty) {
          ptCookies['qrsig'] = qrsig;
          try {
            final attempt = await _attemptCheckSig(
              url: primary,
              query: _checkSigParams(uin, ptsigx),
              jar: ptCookies,
              tag: 'check_sig#2(带qrsig)',
            );
            steps.add(attempt.summary);
            if (chainStart.isEmpty) chainStart = attempt.location;
          } catch (e) {
            steps.add('check_sig#2 异常 ${_describeError(e, '')}');
          }
          gotPskey = (ptCookies['p_skey'] ?? '').isNotEmpty;
        }
      }

      // 1c) 仍无入口时，直接请求 ptuiCB 返回的服务端 check_sig URL
      if (!gotPskey && chainStart.isEmpty) {
        final jump = ptuiJumpUrl.replaceAll('&amp;', '&');
        final uri = Uri.tryParse(jump);
        if (jump.isNotEmpty && uri != null && uri.path.endsWith('check_sig')) {
          try {
            final attempt = await _attemptCheckSig(
                url: jump, jar: ptCookies, tag: 'check_sig#3(服务端URL)');
            steps.add(attempt.summary);
            if (chainStart.isEmpty) chainStart = attempt.location;
          } catch (e) {
            steps.add('check_sig#3 异常 ${_describeError(e, '')}');
          }
          gotPskey = (ptCookies['p_skey'] ?? '').isNotEmpty;
        }
      }

      _log('check_sig 阶段结束：p_skey=$gotPskey '
          'jar=[${ptCookies.keys.join(',')}] '
          'p_skey值=${_mask(ptCookies['p_skey'])} '
          'OAuth链入口=${_maskUrl(chainStart)}');

      // 2) 取授权 code（三条路，谁先拿到用谁）：
      //    2a) 有 p_skey → 参考实现 authorize（g_tk=hash33(p_skey,5381)）；
      //    2b) 跟随 check_sig 的 302（实扫证据：→ graph.qq.com/oauth2.0/login_jump）
      //        的 OAuth 跳转链，从 Location / HTML 里取 code（不依赖 p_skey）；
      //    2c) 兜底：p_skey 为空也带全部 jar cookie 试 authorize。
      var code = '';
      if (gotPskey) {
        code = await _authorizeForCode(ptCookies, ptCookies['p_skey']!);
      }
      if (code.isEmpty && chainStart.isNotEmpty) {
        _log('尝试跟随 OAuth 链取 code：${_maskUrl(chainStart)} '
            'len=${chainStart.length}');
        code = await _codeFromOAuthChain(startUrl: chainStart, jar: ptCookies);
        if (code.isNotEmpty) {
          _lastError = null;
          _log('OAuth 链取到 code=${_mask(code)}');
        }
      }
      // OAuth 链过程中若补发了 p_skey，再走一次 authorize
      if (code.isEmpty && (ptCookies['p_skey'] ?? '').isNotEmpty) {
        _log('OAuth 链后补发 p_skey=${_mask(ptCookies['p_skey'])}，重试 authorize');
        code = await _authorizeForCode(ptCookies, ptCookies['p_skey']!);
      }
      if (code.isEmpty) {
        _log('兜底：p_skey=${_mask(ptCookies['p_skey'])} 时也尝试 authorize');
        code = await _authorizeForCode(ptCookies, ptCookies['p_skey'] ?? '');
      }
      if (code.isEmpty) {
        final detail = steps.isEmpty ? '无有效响应' : steps.join('；');
        _lastError = 'QQ 扫码已确认，但未取到授权 code'
            '（p_skey=${gotPskey ? '有' : '空'}；'
            'OAuth链=${chainStart.isEmpty ? '无入口' : '已尝试'}；'
            'check_sig: ${_short(detail, 300)}）';
        _log(_lastError!);
        return null;
      }
      _lastError = null;
      _log('授权 code 已取得（${_mask(code)}），进入 QQLogin');

      // 3) QQLogin：主 base 失败（网络/5xx/JSON 异常/业务 code!=0）自动切备用 base
      for (final base in _qqLoginCandidates) {
        try {
          final resp = await JXHttp.dio.get(base,
              queryParameters: {
                'format': 'json',
                'data': jsonEncode(_qqLoginPayload(code)),
              },
              options: Options(headers: {'Referer': 'https://y.qq.com/'}));
          final raw = resp.data;
          if (raw is! Map) {
            _lastError = 'QQLogin 响应非 JSON（HTTP ${resp.statusCode}，$base）';
            continue;
          }
          final req = raw['req'] ?? raw['req_0'];
          final outerCode = raw['code'];
          if (req is! Map) {
            _lastError = 'QQLogin 响应缺 req（HTTP ${resp.statusCode}，'
                '外层 code=$outerCode，$base）';
            continue;
          }
          final bizCode = req['code'];
          final data = req['data'];
          final bizOk = bizCode == null || bizCode == 0 || '$bizCode' == '0';
          final dataKeys =
              data is Map ? data.keys.map((e) => '$e').join(',') : '-';
          _log('QQLogin[$base] HTTP ${resp.statusCode} 外层code=$outerCode '
              '业务code=$bizCode dataKeys=[$dataKeys]');
          if (data is Map && bizOk) {
            _lastError = null;
            return Map<String, dynamic>.from(data);
          }
          _lastError = 'QQLogin 返回 code=${bizCode ?? outerCode}（$base）';
        } catch (e) {
          _lastError = _describeError(e, 'QQLogin 请求失败（$base）');
          _log(_lastError!);
        }
      }
      return null;
    } catch (e) {
      _lastError = _describeError(e, 'QQ 登录态兑换失败');
      _log(_lastError!);
      return null;
    }
  }

  /// 提取 302 Location（大小写兼容）里的 code；Location 缺失/延迟时兜底解析响应体
  String _extractCode(Response<dynamic> resp) {
    final location = _headerValue(resp.headers, 'location');
    final fromLocation = _extractCodeFromText(location);
    if (fromLocation.isNotEmpty) return fromLocation;
    return _extractCodeFromText('${resp.data}');
  }

  /// 从文本（URL / HTML / JS）里提取 OAuth 授权 code。
  /// 只接受 `?code=` / `&code=`（排除 errcode/retcode 等干扰）且长度 >= 8。
  String _extractCodeFromText(String text) {
    if (text.isEmpty) return '';
    final m = RegExp(r'[?&]code=([A-Za-z0-9_\-]{8,})').firstMatch(text);
    return m?.group(1) ?? '';
  }

  /// authorize：先 POST 表单，取不到 code 时无条件降级 GET。
  /// 实扫证据下 p_skey 可能为空值，此时 g_tk 用空串计算（部分服务端分支仍接受），
  /// 只要 jar 里还有 pt4_token/pt_oauth_token 等 cookie 就有机会拿到 code。
  /// redirect_uri 做两种编码候选（双重编码 / 明文），按顺序尝试。
  Future<String> _authorizeForCode(
      Map<String, String> jar, String pSkey) async {
    for (final redirectUri in _authorizeRedirectUris) {
      for (final base in _authorizeCandidates) {
        final params = _authorizeParams(pSkey, redirectUri);
        final headers = {
          'Referer': 'https://graph.qq.com/',
          'Cookie': _cookieStr(jar),
        };
        Response<dynamic>? resp;
        var code = '';
        try {
          resp = await JXHttp.dio.post(base,
              data: params,
              options: Options(
                contentType: Headers.formUrlEncodedContentType,
                followRedirects: false,
                validateStatus: (s) => s != null && s < 500,
                receiveTimeout: const Duration(seconds: 10),
                headers: headers,
              ));
        } catch (e) {
          _lastError = _describeError(e, 'authorize POST 失败（$base）');
          _log(_lastError!);
        }
        final postLoc =
            resp == null ? '' : _headerValue(resp.headers, 'location');
        code = resp == null ? '' : _extractCode(resp);
        _log('authorize POST HTTP ${resp?.statusCode ?? '-'} '
            'redirect_uri=${_mask(redirectUri, head: 40, tail: 20)} '
            'Location=${_maskUrl(postLoc)} locLen=${postLoc.length} '
            'codeLen=${code.length} code=${_mask(code)}');
        if (code.isEmpty) {
          try {
            resp = await JXHttp.dio.get(base,
                queryParameters: params,
                options: Options(
                  followRedirects: false,
                  validateStatus: (s) => s != null && s < 500,
                  receiveTimeout: const Duration(seconds: 10),
                  headers: headers,
                ));
          } catch (e) {
            _lastError = _describeError(e, 'authorize GET 降级失败（$base）');
            _log(_lastError!);
            resp = null;
          }
          final getLoc =
              resp == null ? '' : _headerValue(resp.headers, 'location');
          code = resp == null ? '' : _extractCode(resp);
          _log('authorize GET HTTP ${resp?.statusCode ?? '-'} '
              'redirect_uri=${_mask(redirectUri, head: 40, tail: 20)} '
              'Location=${_maskUrl(getLoc)} locLen=${getLoc.length} '
              'codeLen=${code.length} code=${_mask(code)}');
        }
        if (code.isNotEmpty) return code;
        _lastError = 'authorize 未取到 code（HTTP ${resp?.statusCode ?? '-'}，'
            '$base）';
      }
    }
    return '';
  }

  /// 从 check_sig 的 302 入口（实扫：graph.qq.com/oauth2.0/login_jump）开始，
  /// 带全部 jar cookie 跟随 OAuth 跳转链（最多 5 跳），从 Location / HTML / JS
  /// 里取授权 code。每跳只输出：状态、Location 打码+长度、Set-Cookie 摘要、
  /// body 长度与关键特征（是否含 code=/oauth2.0/script），不打印明文 URL/body
  /// （QA D-01 隐私要求）。
  Future<String> _codeFromOAuthChain({
    required String startUrl,
    required Map<String, String> jar,
  }) async {
    var url = startUrl;
    var referer = 'https://graph.qq.com/';
    for (var hop = 1; hop <= 5; hop++) {
      if (url.isEmpty) break;
      Response<dynamic> resp;
      try {
        resp = await _getRaw(url, headers: {
          'Referer': referer,
          if (jar.isNotEmpty) 'Cookie': _cookieStr(jar),
        });
      } catch (e) {
        _log('OAuth链#$hop 请求异常：${_describeError(e, '')}');
        return '';
      }
      _collectSetCookies(resp.headers, jar);
      final status = resp.statusCode ?? 0;
      final location = _headerValue(resp.headers, 'location');
      final body = '${resp.data ?? ''}';
      final fromLocation = _extractCodeFromText(location);
      final fromBody = _extractCodeFromText(body);
      _log('OAuth链#$hop 请求=${_maskUrl(url)}');
      _log('OAuth链#$hop HTTP=$status '
          'jar=[${jar.keys.join(',')}] p_skey=${_mask(jar['p_skey'])}');
      _log('OAuth链#$hop Location=${_maskUrl(location)} '
          'locLen=${location.length}');
      _log('OAuth链#$hop Set-Cookie原始: ${_setCookieDigest(resp.headers)}');
      _log('OAuth链#$hop bodyLen=${body.length} '
          'hasCode=${body.contains('code=')} '
          'hasOauth=${body.contains('oauth2.0/')} '
          'hasScript=${body.contains('script')}');
      _log('OAuth链#$hop code: location=${_mask(fromLocation)} '
          'body=${_mask(fromBody)}');
      if (fromLocation.isNotEmpty) return fromLocation;
      if (fromBody.isNotEmpty) return fromBody;

      var next = _nextUrlFromBody(body);
      if (next.isEmpty) {
        if (location.isEmpty) return '';
        next = location.startsWith('http')
            ? location
            : Uri.parse(url).resolve(location).toString();
      }
      if (next == url) return '';
      referer = url;
      url = next;
    }
    return '';
  }

  /// 从 HTML/JS 响应体里找"下一页"URL（graph oauth show / login_jump / meta refresh）
  String _nextUrlFromBody(String body) {
    if (body.isEmpty) return '';
    final m1 = RegExp(r'''window\.location(?:\.href)?\s*=\s*['"]([^'"]+)['"]''')
        .firstMatch(body);
    if (m1 != null) return m1.group(1) ?? '';
    final m2 = RegExp(r'''location\.replace\(\s*['"]([^'"]+)['"]''')
        .firstMatch(body);
    if (m2 != null) return m2.group(1) ?? '';
    final m3 = RegExp(r'''<(?:meta|META)[^>]+url=([^"'>\s]+)''')
        .firstMatch(body);
    if (m3 != null) return m3.group(1) ?? '';
    final m4 =
        RegExp(r'''https?://[^\s"'<>]+oauth2\.0/[^\s"'<>]+''').firstMatch(body);
    return m4?.group(0) ?? '';
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

/// `ptuiCB(...)` 回调解析结果
class PtuiCbResult {
  /// 状态码：0 登录成功、65 已过期、66 未扫码、67 已扫码待确认、7 参数错误
  final String code;

  /// 登录成功时的跳转 URL（含 uin / ptsigx）
  final String redirectUrl;

  /// 服务端返回的提示文案（可能为 GBK 乱码，仅用于错误展示）
  final String message;

  /// 扫码用户的 QQ 昵称
  final String nickname;

  const PtuiCbResult({
    required this.code,
    required this.redirectUrl,
    required this.message,
    required this.nickname,
  });
}

/// 容错解析 QQ 的 `ptuiCB('code','0','url','0','msg', 'nick')` 响应。
///
/// 真实响应格式并不稳定：最后一项前可能带空格（如 `'', '')`）、字段数可能增减、
/// 文案是 GBK 编码的乱码。因此这里不按固定分组匹配，而是先截取括号内内容，
/// 再把其中所有单引号字符串按顺序取出，避免把正常的等待态误判为"接口异常"。
PtuiCbResult? parsePtuiCb(String text) {
  final body =
      RegExp(r'ptuiCB\((.*?)\)', dotAll: true).firstMatch(text)?.group(1);
  if (body == null) return null;
  final args = <String>[
    for (final m in RegExp(r"'((?:\\.|[^'\\])*)'").allMatches(body))
      m.group(1) ?? '',
  ];
  if (args.isEmpty) return null;
  return PtuiCbResult(
    code: args[0],
    redirectUrl: args.length > 2 ? args[2] : '',
    message: args.length > 4 ? args[4] : '',
    nickname: args.length > 5 ? args[5] : '',
  );
}
