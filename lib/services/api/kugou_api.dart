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

  // ---- 酷狗官方扫码登录（gateway/openapi.kugou.com Web 协议）----
  static const String _gateway = 'https://gateway.kugou.com/v2';
  static const String _kgSalt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
  final Map<String, String> _cookies = {};
  String? _qrKey;

  // 酷狗 Web 签名：公共参数按 key 排序拼接后 MD5(salt+串+salt)
  String _sign(Map<String, dynamic> params) {
    final keys = params.keys.toList()..sort();
    final str = keys.map((k) => '$k=${params[k]}').join('&');
    return md5.convert(utf8.encode('$_kgSalt$str$_kgSalt')).toString();
  }

  String _randomMid() =>
      'JX${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(9999)}';

  /// 搜索接口返回的文本里带 `<em>` 高亮标签（如 `<em>周杰伦</em>`），显示前必须清掉
  static String _clean(String? s) =>
      (s ?? '').replaceAll(RegExp(r'</?em>'), '').trim();

  /// 酷狗图片地址形如 http://imge.kugou.com/stdmusic/{size}/... ，需要替换尺寸并升级 https
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
          vip: (m['Privilege'] as int? ?? 0) > 0,
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
    try {
      final resp = await JXHttp.dio.get(
          'https://krcs.kugou.com/get',
          queryParameters: {'ver': 1, 'hash': song.id, 'platid': 4});
      final content = resp.data['content'] as String?;
      if (content == null || content.isEmpty) return '';
      return utf8.decode(base64Url.decode(content), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  @override
  Future<List<Playlist>> recommendPlaylists(
      {int page = 1, int size = 20}) async {
    return const [];
  }

  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
      {int page = 1, int size = 100}) async {
    // 酷狗歌单详情只有网页版 jsonp 接口（www.kugou.com/yy/special/single/{id}.html），
    // 暂未接入，返回空列表；UI 会提示"该平台暂不支持歌单"。
    return const [];
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

  // ---- 扫码登录（酷狗官方 gateway 扫码协议）----
  @override
  void restoreSession(AccountSession? session) {
    _cookies.clear();
    if (session != null) _cookies.addAll(session.cookies);
    _qrKey = null;
  }

  @override
  Future<({String qrUrl, String key})> createQrLogin() async {
    _cookies.clear();
    _qrKey = null;
    try {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final common = <String, dynamic>{
        'appid': 1014,
        'mid': _randomMid(),
        'uuid': _randomMid(),
        'clienttime': '$now',
        'dfid': '3K9V4B4Z3I9y0M5M0n2T0',
        'signature': '',
      };
      final p1 = Map<String, dynamic>.of(common)..addAll({'scene': 'login', 'code': '23101'});
      final params = Map<String, dynamic>.of(p1)
        ..['signature'] = _sign(p1);
      final resp = await JXHttp.dio.get('$_gateway/login/qr/key',
          queryParameters: params,
          options: Options(headers: {'x-router': 'openapi.kugou.com'}));
      final data = resp.data['data'] as Map<String, dynamic>?;
      final key = data?['key'] as String?;
      if (key == null || key.isEmpty) return (qrUrl: '', key: '');
      _qrKey = key;
      // 二维码内容为酷狗官方 H5 扫码授权页（带 key 参数）
      return (qrUrl: 'https://h5.kugou.com/loginQRCode.html?key=$key', key: key);
    } catch (_) {
      return (qrUrl: '', key: '');
    }
  }

  @override
  Future<AccountSession?> pollQrLogin(String key) async {
    if (_qrKey != key) return null;
    try {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final common = <String, dynamic>{
        'appid': 1014,
        'mid': _randomMid(),
        'uuid': _randomMid(),
        'clienttime': '$now',
        'dfid': '3K9V4B4Z3I9y0M5M0n2T0',
        'signature': '',
      };
      final p1 = Map<String, dynamic>.of(common)
        ..addAll({'key': key, 'scene': 'login', 'code': '23101'});
      final params = Map<String, dynamic>.of(p1)
        ..['signature'] = _sign(p1);
      final resp = await JXHttp.dio.get('$_gateway/login/qr/check',
          queryParameters: params,
          options: Options(headers: {'x-router': 'openapi.kugou.com'}));
      final data = resp.data['data'] as Map<String, dynamic>?;
      final status = data?['status'] as int?;
      if (data == null || status == null || status != 4) {
        return null; // 0/1 等待, 2 已扫码, 3 已确认, 4 成功
      }
      final nickname = data['nickname'] as String? ?? '酷狗用户';
      _cookies['userid'] = '${data['userid'] ?? ''}';
      _cookies['token'] = '${data['token'] ?? ''}';
      return AccountSession(
        platform: platform,
        cookies: Map.of(_cookies),
        nickname: nickname,
      );
    } catch (_) {
      return null;
    }
  }
}
