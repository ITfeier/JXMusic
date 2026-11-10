import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../models/song.dart';
import '../../models/playlist.dart';
import 'music_api.dart';
import 'http.dart';

/// 酷狗音乐接口（公开接口逆向，基础能力无需登录）
class KuGouApi implements MusicPlatformApi {
  @override
  int get platform => 2;

  static const String _search =
      'https://songsearch.kugou.com/song_search_v2';
  static const String _playData = 'https://wwwapi.kugou.com/yy/index.php';
  static const String _songInfo = 'https://m.kugou.com/app/i/getSongInfo.php';

  // ---- 酷狗官方扫码登录（Web 登录页 login-user.kugou.com 协议）----
  // 2026-11-09 实扫定案（假设已验证）：
  // · `v2/get_userinfo_qrcode` 到 status=4 时返回的 **token+userid 就是完整登录态**：
  //   写入 Cookie 后，免费歌曲 `getSongInfo.php` 实测返回 status=1 + 可播 sharefs 直链；
  // · 旧代码调用的 legacy `loginservice.kugou.com/v1/login_by_token_get` 已废弃/协议不符
  //   （返回 20006），它是"登录态不完整"误报的来源 —— 已删除该调用；
  // · v5/login_by_token、register_dev、user_info 等 Android 域接口对 web 型(1014)
  //   token 均返回 20018/20006/20017（本机实测），说明这类数据需要 Android 型 token；
  //   普通账号只要求"普通歌可播"，故保持 web 取码链路不变、不做增强调用。
  static const String _loginBase = 'https://login-user.kugou.com/';
  static const String _qrcodeH5 =
      'https://h5.kugou.com/apps/loginQRCode/html/index.html';
  static const String _kgSalt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
  // Web 登录固定 clientver=8131、plat=4；dfid 无 cookie 时官方 JS 用 '-'
  static const String _clientVer = '8131';
  static const String _dfid = '-';
  static const String _loginReferer =
      'https://login-user.kugou.com/login/?appid=1014';
  final Map<String, String> _cookies = {};
  String? _qrKey;
  String? _kgMid;

  /// 最近一次扫码操作失败原因（成功/等待时为 null，供设置页展示准确提示）
  String? _lastError;

  @override
  String? get lastError => _lastError;

  /// 酷狗 Web 登录签名（kguser.v2.min.js 的 getInterFaceKguser）：
  /// MD5(salt + 按 key 排序的 "k=v" 直接拼接 + salt)，参数间无分隔符，MD5 大写。
  /// 公共参数：srcappid=2919；clientver/clienttime/mid/uuid/dfid 缺省时填充。
  Map<String, String> _sign(Map<String, String> input) {
    final p = Map<String, String>.of(input);
    final nowMs = '${DateTime.now().millisecondsSinceEpoch}';
    p['srcappid'] ??= '2919';
    if ((p['clientver'] ?? '').isEmpty) p['clientver'] = '20000';
    if ((p['clienttime'] ?? '').isEmpty) p['clienttime'] = nowMs;
    if ((p['mid'] ?? '').isEmpty) p['mid'] = nowMs;
    if ((p['uuid'] ?? '').isEmpty) p['uuid'] = nowMs;
    if ((p['dfid'] ?? '').isEmpty) p['dfid'] = '-';
    final keys = p.keys.toList()..sort();
    final joined = keys.map((k) => '$k=${p[k]}').join();
    p['signature'] = md5
        .convert(utf8.encode('$_kgSalt$joined$_kgSalt'))
        .toString()
        .toUpperCase();
    return p;
  }

  /// 酷狗的 mid / uuid 为 32 位小写十六进制（官网用 MD5(GUID) 生成）
  String _randomHex32() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// 会话 cookie 请求头值（只发往 kugou.com 官方域）
  String get _cookieStr => _cookies.entries
      .map((e) => '${e.key}=${e.value}')
      .join('; ');

  /// 搜索接口返回的文本里带 `<em>` 高亮标签（如 `<em>周杰伦</em>`），显示前必须清掉
  static String _clean(String? s) =>
      (s ?? '').replaceAll(RegExp(r'</?em>'), '').trim();

  /// 酷狗图片地址形如 http://imge.kugou.com/stdmusic/{size}/... 或
  /// https://imgessl.kugou.com/custom/{size}/... ，需要替换尺寸并升级 https
  static String _image(String? url) {
    if (url == null || url.isEmpty) return '';
    return jxNormalizeImageUrl(url.replaceAll('{size}', '240'));
  }

  @override
  Future<List<Song>> searchSongs(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final resp = await JXHttp.dio.get(_search, queryParameters: {
        'keyword': keyword,
        'page': page,
        'pagesize': size,
        'platform': 'PCFilter',
        'tag': 'em',
        'filter': '2',
      });
      final lists = ((resp.data['data']?['lists']) as List?) ?? const [];
      return lists.map<Song>((s) {
        final m = s as Map<String, dynamic>;
        final name = _clean(m['SongName'] as String?);
        final singer = _clean(m['SingerName'] as String?);
        final album = _clean(m['AlbumName'] as String?);
        return Song(
          id: m['FileHash'] as String? ?? '',
          platform: platform,
          title: name,
          artist: singer.isEmpty ? '未知歌手' : singer,
          album: album,
          coverUrl: _image(m['Image'] as String?),
          duration: m['TimeLength'] is int
              ? m['TimeLength'] as int
              : int.tryParse('${m['TimeLength']}') ?? 0,
          vip: (m['Privilege'] as int? ?? 0) >= 10,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }


  /// 请求头：仅当已登录时携带 cookie（只发往 kugou.com 官方域）。
  /// 2026-11-09 本机实测：token+userid 写入 Cookie 后，免费歌 getSongInfo
  /// 直接返回 status=1 + 可播 sharefs 直链（不需要 login_by_token_get / tracker）。
  Options? get _authOptions {
    if (_cookies.isEmpty) return null;
    return Options(headers: {'Cookie': _cookieStr});
  }

  @override
  Future<String?> getPlayUrl(Song song) async {
    final hash = song.id;
    if (hash.isEmpty) return null;
    final auth = _authOptions;
    // 主路径：m.kugou getSongInfo（登录后免费歌返回直链；2026-11-09 用真实 token 实测
    // 免费歌返回 status=1 + sharefs 直链；付费/VIP 歌返回 status=0 error="需要付费"）
    try {
      final resp = await JXHttp.dio.get(_songInfo,
          queryParameters: {'cmd': 'playInfo', 'hash': hash, 'platid': 4},
          options: auth);
      final url = resp.data['url'] as String?;
      if (url != null && url.isNotEmpty) return url;
    } catch (_) {
      // 忽略，走兜底
    }
    // 兜底：wwwapi getdata（部分场景可用；dfid/mid 为旧协议占位值，保持原样）
    try {
      final resp = await JXHttp.dio.get(_playData,
          queryParameters: {
            'r': 'play/getdata',
            'hash': hash,
            'album_id': '',
            'dfid': '3K9V4B4Z3I9y0M5M0n2T0',
            'mid': 'JXMusic',
            'platid': 4,
          },
          options: auth);
      final url = resp.data['data']?['play_url'] as String?;
      if (url == null || url.isEmpty) return null;
      return url;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> getLyrics(Song song) async {
    // 官方歌词链路：krcs.kugou.com/search 找候选 -> lyrics.kugou.com/download 取 LRC
    // （返回的 content 是 base64 的 LRC 文本，且带 UTF-8 BOM）
    // PRD R1.2：两跳都补 m.kugou.com Referer（JXHttp 全局默认 Referer 是
    // music.163.com，属加固；已登录时顺带发酷狗会话 cookie，只发 kugou.com 域）。
    final headers = <String, String>{
      'Referer': 'https://m.kugou.com/',
      if (_cookies.isNotEmpty) 'Cookie': _cookieStr,
    };
    try {
      final search = await JXHttp.dio.get(
        'https://krcs.kugou.com/search',
        queryParameters: {
          'ver': 1,
          'man': 'yes',
          'client': 'mobi',
          'keyword': '',
          'duration': song.duration * 1000,
          'hash': song.id,
          'album_audio_id': '',
        },
        options: Options(headers: headers),
      );
      final candidates = (search.data['candidates'] as List?) ?? const [];
      if (candidates.isEmpty) return '';
      final first = candidates.first as Map;
      final id = first['id'];
      final accessKey = first['accesskey'];
      if (id == null || accessKey == null) return '';
      final download = await JXHttp.dio.get(
        'https://lyrics.kugou.com/download',
        queryParameters: {
          'ver': 1,
          'client': 'pc',
          'id': '$id',
          'accesskey': '$accessKey',
          'fmt': 'lrc',
          'charset': 'utf8',
        },
        options: Options(headers: headers),
      );
      final content = download.data['content'] as String?;
      if (content == null || content.isEmpty) return '';
      var text = utf8.decode(
        base64Decode(content.replaceAll(RegExp(r'\s'), '')),
        allowMalformed: true,
      );
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      return text;
    } catch (_) {
      return '';
    }
  }

  @override
  Future<List<Playlist>> recommendPlaylists(
      {int page = 1, int size = 20}) async {
    // m.kugou.com/plist/index 返回推荐歌单（每页 30 条，支持 page 参数）
    try {
      final resp = await JXHttp.dio.get(
        'https://m.kugou.com/plist/index',
        queryParameters: {
          'json': 'true',
          'page': page,
          'pagesize': size,
        },
      );
      final list = (resp.data['plist']?['list']?['info'] as List?) ?? const [];
      return list.map<Playlist>((p) {
        final m = p as Map<String, dynamic>;
        return Playlist(
          id: '${m['specialid']}',
          platform: platform,
          title: _clean(m['specialname'] as String?),
          coverUrl: _image(m['imgurl'] as String?),
          creator: _clean(m['username'] as String?),
          songCount: (m['songcount'] as num?)?.toInt() ?? 0,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
      {int page = 1, int size = 100}) async {
    // mobiles.kugou.com 的歌单详情接口，返回 data.info 歌曲数组
    try {
      final resp = await JXHttp.dio.get(
        'https://mobiles.kugou.com/api/v3/special/song',
        queryParameters: {
          'specialid': playlist.id,
          'page': page,
          'pagesize': size,
          'plat': 0,
          'version': 8000,
        },
      );
      final list = (resp.data['data']?['info'] as List?) ?? const [];
      return list.map<Song>((s) {
        final m = s as Map<String, dynamic>;
        final filename = _clean(m['filename'] as String?);
        final cover = (m['trans_param'] as Map?)?['union_cover'] as String?;
        return Song(
          id: m['hash'] as String? ?? '',
          platform: platform,
          title: filename,
          artist: _parseArtist(filename),
          album: '',
          coverUrl: _image(cover),
          duration: (m['duration'] as num?)?.toInt() ?? 0,
          vip: (m['privilege'] as int? ?? 0) >= 10,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async {
    // 酷狗 TOP500：m.kugou.com/rank/info（2026-11 实测可用；
    // 旧 www.kugou.com/yy/index.php?r=rank/list 已返回 "Access Deny"）
    try {
      final resp = await JXHttp.dio.get('https://m.kugou.com/rank/info/',
          queryParameters: {'rankid': 8888, 'page': page, 'json': 'true'},
          options: Options(headers: {'Referer': 'https://m.kugou.com/'}));
      final root = resp.data;
      final songs = (root is Map ? root['songs'] : null);
      final list = (songs is Map ? songs['list'] as List? : null) ?? const [];
      return list.take(size).map<Song>((s) {
        final m = s as Map;
        final filename = _clean(m['filename'] as String?);
        final cover = (m['trans_param'] as Map?)?['union_cover'] as String? ??
            m['album_sizable_cover'] as String?;
        return Song(
          id: m['hash'] as String? ?? '',
          platform: platform,
          title: filename,
          artist: _parseArtist(filename),
          album: '',
          coverUrl: _image(cover),
          duration: (m['duration'] as num?)?.toInt() ?? 0,
          vip: ((m['privilege'] as num?)?.toInt() ?? 0) >= 10,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  String _parseArtist(String filename) {
    final idx = filename.indexOf(' - ');
    if (idx > 0) return filename.substring(0, idx).trim();
    return '未知歌手';
  }

  // ---- 扫码登录（Web 登录页 login-user.kugou.com 协议）----
  // 2026-11-09 实扫定案（假设已本机验证）：
  // · status=4 返回的 token+userid **就是完整登录态**：写入 Cookie 后免费歌曲
  //   getSongInfo 实测返回 status=1 + 可播 sharefs 直链；
  // · legacy `login_by_token_get` 已废弃（20006），是"登录态不完整"误报来源 → 删除；
  // · v5/login_by_token、register_dev、user_info 对 web 型(1014) token 返回
  //   20018/20006/20017（本机实测），这类数据需要 Android 型 token；
  //   普通账号只要求普通歌可播，故保持 web 取码链路不变、不做增强调用。
  @override
  void restoreSession(AccountSession? session) {
    _cookies.clear();
    if (session != null) _cookies.addAll(session.cookies);
    _qrKey = null;
    _kgMid = null;
  }

  @override
  Future<({String qrUrl, String key})> createQrLogin() async {
    _qrKey = null;
    _kgMid = _randomHex32();
    _lastError = null;
    try {
      // GET https://login-user.kugou.com/v2/qrcode?<签名参数>
      final params = <String, String>{
        'appid': '1014',
        'clientver': _clientVer,
        'clienttime': '${DateTime.now().millisecondsSinceEpoch}',
        'mid': _kgMid!,
        'uuid': _kgMid!,
        'dfid': _dfid,
        'type': '1',
        'plat': '4',
        'qrcode_txt': '$_qrcodeH5?appid=1014&',
      };
      final resp = await JXHttp.dio.get(
        '${_loginBase}v2/qrcode',
        queryParameters: _sign(params),
        options: Options(headers: {'Referer': _loginReferer}),
      );
      final data = resp.data is Map ? resp.data['data'] : null;
      final key = data is Map ? '${data['qrcode'] ?? ''}' : '';
      if (key.isEmpty) {
        _lastError = '酷狗取码返回空 key（接口可能已变更）';
        return (qrUrl: '', key: '');
      }
      _qrKey = key;
      // 官方同时返回 data.qrcode_img（data:image/png;base64,...）；缺失时退化为 H5 URL
      final img = data is Map ? '${data['qrcode_img'] ?? ''}' : '';
      final qrUrl =
          img.isNotEmpty ? img : '$_qrcodeH5?appid=1014&qrcode=$key';
      _lastError = null;
      return (qrUrl: qrUrl, key: key);
    } catch (e) {
      _lastError = _describeError(e, '酷狗二维码获取失败');
      return (qrUrl: '', key: '');
    }
  }

  /// 把网络异常翻译成用户能看懂的原因
  String _describeError(Object error, String prefix) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code != null) return '$prefix：HTTP $code';
      return '$prefix：网络不可达（${error.type.name}）';
    }
    return '$prefix：$error';
  }

  @override
  Future<AccountSession?> pollQrLogin(String key) async {
    if (key.isEmpty || _qrKey != key) return null;
    try {
      // GET https://login-user.kugou.com/v2/get_userinfo_qrcode?<签名参数>
      // data.status：0 过期 / 1 等待 / 2 已扫码待确认 / 4 登录成功
      final mid = _kgMid ?? _randomHex32();
      final params = <String, String>{
        'appid': '1014',
        'clientver': _clientVer,
        'clienttime': '${DateTime.now().millisecondsSinceEpoch}',
        'mid': mid,
        'uuid': mid,
        'dfid': _dfid,
        'plat': '4',
        'qrcode': key,
      };
      final resp = await JXHttp.dio.get(
        '${_loginBase}v2/get_userinfo_qrcode',
        queryParameters: _sign(params),
        options: Options(headers: {'Referer': _loginReferer}),
      );
      final root = resp.data is Map ? resp.data as Map : null;
      if (root == null) {
        _lastError = '酷狗轮询返回空响应（接口可能已变更）';
        return null;
      }
      final data = root['data'];
      if (data is! Map) {
        final code = root['error_code'];
        if (code != null && '$code' != '0') {
          _lastError = '酷狗轮询失败（error_code=$code）';
        } else {
          _lastError = null; // 等待态
        }
        return null;
      }
      final status = (data['status'] as num?)?.toInt() ?? 0;
      if (status == 2) {
        _lastError = null; // 已扫码待确认
        return null;
      }
      if (status == 0) {
        _lastError = '二维码已过期，请关闭后重新获取';
        return null;
      }
      if (status != 4) {
        _lastError = null; // 其余按等待处理
        return null;
      }
      // status=4：token+userid 就是完整登录态（本机实测可正常取免费歌直链）
      final userid = '${data['userid'] ?? ''}';
      final token = '${data['token'] ?? ''}';
      if (userid.isEmpty || token.isEmpty) {
        _lastError = '酷狗登录成功但服务端未返回 token/userid';
        return null;
      }
      _cookies['userid'] = userid;
      _cookies['token'] = token;
      var nickname = '${data['nickname'] ?? ''}'.trim();
      if (nickname.isEmpty) nickname = (_cookies['nickname'] ?? '').trim();
      final pic = '${data['pic'] ?? data['headimg'] ?? ''}';
      _lastError = null;
      return AccountSession(
        platform: platform,
        cookies: Map.of(_cookies),
        nickname: nickname.isEmpty ? '酷狗用户' : nickname,
        avatarUrl: pic.isEmpty ? null : jxNormalizeImageUrl(pic),
      );
    } catch (e) {
      _lastError = _describeError(e, '酷狗扫码轮询失败');
      return null;
    }
  }
}
