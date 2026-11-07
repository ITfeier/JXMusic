import 'dart:convert';
import 'package:dio/dio.dart';
import '../../models/song.dart';
import '../../models/playlist.dart';
import 'music_api.dart';
import 'http.dart';
import 'netease_crypto.dart';

/// 网易云音乐接口（基于公开逆向 webapi）
class NeteaseApi implements MusicPlatformApi {
  @override
  int get platform => 1;

  // 公开 webapi 接口（无登录态基础能力）
  static const String _base = 'https://music.163.com/api';
  static const String _baseWeb = 'https://music.163.com/weapi';
  static const String _musicBase = 'https://music.163.com';

  Map<String, String> _cookies = {};

  @override
  Future<List<Song>> searchSongs(String keyword,
      {int page = 1, int size = 30}) async {
    final offset = (page - 1) * size;
    final data = {
      's': keyword,
      'type': 1,
      'limit': size,
      'offset': offset,
      'total': true,
    };
    try {
      final resp = await _weapi('/api/cloudsearch/pc/search/get', data);
      final result = resp['result'] as Map<String, dynamic>?;
      final songs = (result?['songs'] as List?) ?? const [];
      return songs.map<Song>((s) {
        final m = s as Map<String, dynamic>;
        final artists = (m['ar'] as List? ?? m['artists'] as List? ?? [])
            .map((a) => (a as Map)['name'] as String? ?? '')
            .join('、');
        final album = m['al'] as Map<String, dynamic>? ??
            m['album'] as Map<String, dynamic>?;
        final fee = m['fee'] as int? ?? 0;
        return Song(
          id: '${m['id']}',
          platform: platform,
          title: m['name'] as String? ?? '',
          artist: artists,
          album: album?['name'] as String? ?? '',
          coverUrl: _cover(album?['picUrl'] as String?),
          duration: (m['dt'] as int? ?? 0) ~/ 1000,
          vip: fee == 1 || fee == 4,
        );
      }).toList();
    } catch (e) {
      return const [];
    }
  }

  String _cover(String? url) => jxNormalizeImageUrl(url);

  @override
  Future<String?> getPlayUrl(Song song) async {
    try {
      final sid = int.parse(song.id);
      final data = {
        'ids': jsonEncode([sid]),
        'level': 'standard', // standard/higher/exhigh/lossless/hires
        'encodeType': 'aac',
      };
      final resp = await _weapi('/api/song/enhance/player/url/v1', data);
      final dataList = resp['data'] as List? ?? [];
      if (dataList.isEmpty) return null;
      final first = dataList.first as Map<String, dynamic>;
      final url = first['url'] as String?;
      if (url == null || url.isEmpty) return null;
      return url;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> getLyrics(Song song) async {
    try {
      final data = {'id': song.id, 'lv': -1, 'tv': -1, 'rv': -1};
      final resp = await _weapi('/api/song/lyric/v1', data);
      final lrc = resp['lrc'] as Map<String, dynamic>?;
      return lrc?['lyric'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<List<Playlist>> recommendPlaylists(
      {int page = 1, int size = 20}) async {
    try {
      final resp = await JXHttp.dio.get(
          '$_musicBase/api/playlist/list',
          queryParameters: {'cat': '全部', 'limit': size, 'offset': (page - 1) * size});
      final list = (resp.data['playlists'] as List?) ?? [];
      return list.map<Playlist>((p) {
        final m = p as Map<String, dynamic>;
        return Playlist(
          id: '${m['id']}',
          platform: platform,
          title: m['name'] as String? ?? '',
          coverUrl: jxNormalizeImageUrl(m['coverImgUrl'] as String?),
          creator: (m['creator'] as Map?)?['nickname'] as String? ?? '',
          songCount: m['trackCount'] as int? ?? 0,
          detailUrl: null,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
      {int page = 1, int size = 100}) async {
    try {
      final resp = await JXHttp.dio.get('$_base/v3/playlist/detail',
          queryParameters: {'id': playlist.id});
      final detail = resp.data['playlist'] as Map<String, dynamic>?;
      final tracks = (detail?['tracks'] as List?) ?? [];
      return tracks.map<Song>((s) {
        final m = s as Map<String, dynamic>;
        final artists = (m['ar'] as List? ?? [])
            .map((a) => (a as Map)['name'] as String? ?? '')
            .join('、');
        return Song(
          id: '${m['id']}',
          platform: platform,
          title: m['name'] as String? ?? '',
          artist: artists,
          album: (m['al'] as Map?)?['name'] as String? ?? '',
          coverUrl: _cover((m['al'] as Map?)?['picUrl'] as String?),
          duration: (m['dt'] as int? ?? 0) ~/ 1000,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async {
    try {
      // 云音乐飙升榜 id=19723756
      final resp = await JXHttp.dio.get('$_musicBase/api/v6/playlist/detail',
          queryParameters: {'id': 19723756, 'n': 100});
      final tracks = (resp.data['playlist']['tracks'] as List?) ?? [];
      return tracks.map<Song>((s) {
        final m = s as Map<String, dynamic>;
        final artists = (m['ar'] as List? ?? [])
            .map((a) => (a as Map)['name'] as String? ?? '')
            .join('、');
        return Song(
          id: '${m['id']}',
          platform: platform,
          title: m['name'] as String? ?? '',
          artist: artists,
          album: (m['al'] as Map?)?['name'] as String? ?? '',
          coverUrl: _cover((m['al'] as Map?)?['picUrl'] as String?),
          duration: (m['dt'] as int? ?? 0) ~/ 1000,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  // ---- 扫码登录（公开二维码登录流程）----
  @override
  Future<({String qrUrl, String key})> createQrLogin() async {
    // 旧接口 /login/qr/key + /login/qr/create 已下线（302→404），
    // 改用公开接口 api/login/qrcode/unikey 获取 unikey，二维码内容为官方登录页。
    final resp = await JXHttp.dio.post('$_musicBase/api/login/qrcode/unikey',
        data: {'type': 1},
        options: Options(contentType: 'application/x-www-form-urlencoded'));
    final key = resp.data['unikey'] as String? ?? '';
    if (key.isEmpty) throw Exception('unikey empty');
    return (qrUrl: 'https://music.163.com/login?codekey=$key', key: key);
  }

  @override
  Future<AccountSession?> pollQrLogin(String key) async {
    final resp = await JXHttp.dio.post(
        '$_musicBase/api/login/qrcode/client/login',
        data: {'key': key, 'type': 1},
        options: Options(contentType: 'application/x-www-form-urlencoded'));
    final code = resp.data['code'] as int?;
    if (code != 803) return null;
    // 803：已扫码确认成功，响应含 cookie 与 profile
    final rawCookie =
        resp.data['cookie'] as String? ?? resp.data['token'] as String? ?? '';
    _cookies = _parseCookies(rawCookie);
    final profile = resp.data['profile'] as Map?;
    final nickname = profile?['nickname'] as String? ??
        resp.data['nickname'] as String? ??
        '';
    return AccountSession(
      platform: platform,
      cookies: _cookies,
      nickname: nickname,
    );
  }

  Map<String, String> _parseCookies(String raw) {
    final map = <String, String>{};
    for (final part in raw.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length == 2) map[kv[0]] = kv[1];
    }
    return map;
  }

  @override
  void restoreSession(AccountSession? session) {
    _cookies = Map<String, String>.of(session?.cookies ?? const {});
  }

  /// weapi 加密请求
  Future<Map<String, dynamic>> _weapi(String path, Map<String, dynamic> data) async {
    final enc = NeteaseCrypto.weapi(data);
    final resp = await JXHttp.dio.post(
      '$_baseWeb$path',
      data: {'params': enc['params'], 'encSecKey': enc['encSecKey']},
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        headers: {
          if (_cookies.isNotEmpty)
            'Cookie': _cookies.entries
                .map((e) => '${e.key}=${e.value}')
                .join('; '),
          'Referer': 'https://music.163.com/',
        },
      ),
    );
    return resp.data as Map<String, dynamic>;
  }
}
