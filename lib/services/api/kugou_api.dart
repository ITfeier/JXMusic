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
  static const String _top = 'https://www.kugou.com/yy/index.php';

  // ---- 酷狗官方扫码登录（Web 登录页 login-user.kugou.com 协议）----
  // 协议来源：www.kugou.com 登录弹窗 popuplogin.v3.min.js + kguser.v2.min.js
  // 的 KgUser.GetQRCode / GetQRCodeState。2026-11 实测：取码 HTTP 200 返回
  // qrcode key + data-uri PNG，轮询返回等待态（data.status=1）。
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

  @override
  Future<String?> getPlayUrl(Song song) async {
    // 主路径：m.kugou getSongInfo（免费歌返回直链，2026-10 实测可用；
    // 付费歌 url 为空需登录态）
    try {
      final resp = await JXHttp.dio.get(_songInfo, queryParameters: {
        'cmd': 'playInfo',
        'hash': song.id,
        'platid': 4,
      });
      final url = resp.data['url'] as String?;
      if (url != null && url.isNotEmpty) return url;
    } catch (_) {
      // 忽略，走兜底
    }
    // 兜底：wwwapi getdata（部分场景可用）
    try {
      final resp = await JXHttp.dio.get(_playData, queryParameters: {
        'r': 'play/getdata',
        'hash': song.id,
        'album_id': '',
        'dfid': '3K9V4B4Z3I9y0M5M0n2T0',
        'mid': 'JXMusic',
        'platid': 4,
      });
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
    try {
      // 酷狗 TOP500: rankid 8888
      final resp = await JXHttp.dio.get(_top, queryParameters: {
        'r': 'rank/list',
        'rankid': 8888,
        'page': page,
        'pagesize': size,
        'platid': 4,
      });
      final list = ((resp.data['data']?['songs']) as List?) ?? const [];
      return list.map<Song>((s) {
        final m = s as Map<String, dynamic>;
        final filename = _clean(m['filename'] as String?);
        return Song(
          id: m['hash'] as String? ?? '',
          platform: platform,
          title: filename,
          artist: _parseArtist(filename),
          album: _clean(m['album_name'] as String?),
          coverUrl: _image(m['img'] as String?),
          duration: (m['duration'] as int? ?? 0) ~/ 1000,
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

  // ---- 扫码登录（酷狗官方 Web 登录协议，login-user.kugou.com）----
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
      // 官方同时返回 data.qrcode_img（`data:image/png;base64,...`，官方二维码图片）；
      // 缺失时退化为官方 H5 扫码授权页 URL，由 qr_flutter 渲染成二维码。
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
      // 返回 data.status：0 过期 / 1 等待 / 2 已扫码待确认 / 4 登录成功
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
      if (root['status'] != 1) {
        final code = root['error_code'];
        _lastError = '酷狗轮询失败（error_code=$code）';
        return null;
      }
      final data = root['data'];
      if (data is! Map) {
        _lastError = '酷狗轮询返回数据异常';
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
      final userid = '${data['userid'] ?? ''}';
      final token = '${data['token'] ?? ''}';
      if (userid.isEmpty && token.isEmpty) {
        _lastError = '酷狗登录成功但凭证缺失';
        return null;
      }
      final nickname = '${data['nickname'] ?? ''}'.trim();
      final pic = '${data['pic'] ?? data['headimg'] ?? ''}';
      _cookies['userid'] = userid;
      _cookies['token'] = token;
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
