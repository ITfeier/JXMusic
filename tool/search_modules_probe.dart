// 三平台分类搜索（歌单/歌手/专辑/歌词）、用户歌单、歌手/专辑详情端点探针（v3）。
// 仅开发期诊断，不进入应用构建。运行：
//   dart run tool/search_modules_probe.dart [netease|qq|kugou|user|detail|all]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:jxmusic/services/api/kugou_login_crypto.dart';

const kw = '周杰伦';
const ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

void main(List<String> args) async {
  final mode = args.isEmpty ? 'all' : args.first;
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    validateStatus: (s) => s != null && s < 500,
  ));
  try {
    if (mode == 'netease' || mode == 'all') await _netease(dio);
    if (mode == 'qq' || mode == 'all') await _qqMusicu(dio);
    if (mode == 'kugou' || mode == 'all') await _kugou(dio);
    if (mode == 'user' || mode == 'all') await _userPlaylists(dio);
    if (mode == 'detail' || mode == 'all') await _details(dio);
  } finally {
    dio.close();
  }
}

dynamic _parse(Response resp) {
  final d = resp.data;
  if (d is String) {
    try {
      return jsonDecode(d);
    } catch (_) {
      return null;
    }
  }
  return d;
}

void _printObj(String tag, Object? o, [int max = 1000]) {
  final s = jsonEncode(o);
  print('  $tag: ${s.length > max ? '${s.substring(0, max)}…' : s}');
}

/// 递归找出 Map 里第一个非空 List 的路径与首元素
void _showFirstList(String tag, Map m, [int depth = 4]) {
  if (depth <= 0) return;
  for (final e in m.entries) {
    final v = e.value;
    if (v is List && v.isNotEmpty && v.first is Map) {
      _printObj('$tag.${e.key}[0]', v.first, 900);
      return;
    }
    if (v is Map && v.isNotEmpty) {
      _showFirstList('$tag.${e.key}', v, depth - 1);
    }
  }
}

Future<void> _netease(Dio dio) async {
  print('========== 网易云 分类搜索（api/search/get/web） ==========');
  const types = {'1000': '歌单', '100': '歌手', '10': '专辑', '1006': '歌词'};
  for (final e in types.entries) {
    try {
      final resp = await dio.get(
        'https://music.163.com/api/search/get/web',
        queryParameters: {
          's': kw, 'type': e.key, 'limit': 3, 'offset': 0, 'total': 'true',
        },
        options: Options(
            headers: {'Referer': 'https://music.163.com/', 'User-Agent': ua}),
      );
      final root = _parse(resp) as Map?;
      print('[type=${e.key} ${e.value}] http=${resp.statusCode}');
      if (root == null) {
        print('  解析失败');
        continue;
      }
      print('  code=${root['code']}');
      final result = root['result'];
      if (result is Map) {
        _showFirstList('result', result);
      }
    } catch (err) {
      print('[type=${e.key} ${e.value}] 异常: $err');
    }
  }
}

Future<void> _qqMusicu(Dio dio) async {
  print('========== QQ A. client_search_cp 逐 t 探查 ==========');
  for (final t in const ['0', '1', '3', '4', '5', '6', '7', '8', '9']) {
    try {
      final resp = await dio.get(
        'https://c.y.qq.com/soso/fcgi-bin/client_search_cp',
        queryParameters: {
          'p': 1, 'n': 2, 'w': kw, 't': t,
          'format': 'json', 'inCharset': 'utf8', 'outCharset': 'utf-8',
        },
        options: Options(headers: {'Referer': 'https://y.qq.com/', 'User-Agent': ua}),
      );
      final root = _parse(resp) as Map?;
      final data = root?['data'];
      if (data is Map) {
        final filled = <String>[];
        for (final e in data.entries) {
          final v = e.value;
          if (v is Map) {
            final l = v['list'];
            if (l is List && l.isNotEmpty) filled.add('${e.key}(${l.length})');
          }
        }
        print('[t=$t] http=${resp.statusCode} 填充分区: $filled');
        if (filled.isNotEmpty && t != '0') {
          final first = data[filled.first.split('(').first]['list'][0];
          _printObj('  ${filled.first}[0]', first, 500);
        }
      } else {
        print('[t=$t] http=${resp.statusCode} data=null');
      }
    } catch (err) {
      print('[t=$t] 异常: $err');
    }
  }

  print('========== QQ B. musicu songlist 专项（tmeLoginType） ==========');
  try {
    final resp = await dio.post(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      data: jsonEncode({
        'comm': {'ct': 19, 'cv': 1859, 'uin': 0, 'tmeLoginType': 2},
        'req': {
          'method': 'DoSearchForQQMusicDesktop',
          'module': 'music.search.SearchCgiService',
          'param': {'search_type': 'songlist', 'query': kw, 'page_num': 1, 'num_per_page': 3},
        },
      }),
      options: Options(contentType: 'application/json', headers: {
        'Referer': 'https://y.qq.com/', 'Origin': 'https://y.qq.com', 'User-Agent': ua}),
    );
    final root = _parse(resp) as Map?;
    final body = root?['req']?['data']?['body'];
    if (body is Map) {
      for (final section in const ['song', 'singer', 'album', 'songlist']) {
        final list = body[section]?['list'];
        print('  $section.list 长度: ${list is List ? list.length : list}');
        if (list is List && list.isNotEmpty && section != 'song') {
          _printObj('  $section[0]', list.first, 700);
        }
      }
    } else {
      print('  body=null code=${root?['req']?['code']}');
    }
  } catch (err) {
    print('  异常: $err');
  }

  print('========== QQ C. client_music_search_songlist ==========');
  try {
    final resp = await dio.get(
      'https://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist',
      queryParameters: {
        'remoteplace': 'txt.yqq.songlist_search', 'searchid': '0',
        'query': kw, 'page_no': 1, 'num_per_page': 3,
        'format': 'json', 'inCharset': 'utf8', 'outCharset': 'utf-8',
      },
      options: Options(headers: {'Referer': 'https://y.qq.com/', 'User-Agent': ua}),
    );
    final root = _parse(resp) as Map?;
    if (root is Map) {
      print('  http=${resp.statusCode} code=${root['code']} keys=${root.keys.toList()}');
      final list = root['data']?['list'] ?? root['songlist']?['list'];
      if (list is List && list.isNotEmpty) {
        _printObj('list[0]', list.first, 800);
      } else {
        _printObj('root', root, 600);
      }
    } else {
      print('  原始: ${resp.data.toString().substring(0, 150)}');
    }
  } catch (err) {
    print('  异常: $err');
  }
}

Future<void> _kugou(Dio dio) async {
  print('========== 酷狗 分类搜索（gateway /v1/search/* android 签名） ==========');
  const types = ['special', 'author', 'album', 'lyric'];
  final mid = _randomMid();
  for (final type in types) {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final params = <String, String>{
      'keyword': kw,
      'page': '1',
      'pagesize': '3',
      'platform': 'AndroidFilter',
      'iscorrection': '1',
      'nocollect': '0',
      'albumhide': '0',
      'dfid': '-',
      'mid': mid,
      'uuid': '-',
      'appid': KugouLoginCrypto.appid,
      'clientver': KugouLoginCrypto.clientver,
      'clienttime': '$clienttime',
    };
    if (type == 'album') {
      params['category'] = '1';
      params['sorttype'] = '0';
      params['searchsong'] = '0';
    }
    params['signature'] = KugouLoginCrypto.androidSignature(params, '');
    try {
      final resp = await dio.get(
        'https://gateway.kugou.com/v1/search/$type',
        queryParameters: params,
        options: Options(headers: {
          'x-router': 'complexsearch.kugou.com',
          'User-Agent':
              'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
          'dfid': '-',
          'mid': mid,
          'clienttime': '$clienttime',
        }),
      );
      final root = _parse(resp) as Map?;
      print('[$type] http=${resp.statusCode}');
      if (root == null) {
        print('  解析失败');
        continue;
      }
      print('  status=${root['status']} error_code=${root['error_code']}');
      final data = root['data'];
      if (data is Map) {
        print('  data.keys=${data.keys.toList()}');
        _showFirstList('data', data);
      }
    } catch (err) {
      print('[$type] 异常: $err');
    }
  }
}

Future<void> _userPlaylists(Dio dio) async {
  print('========== 用户歌单接口形状 ==========');
  // --- 网易云：搜索歌单结果里的 creator.userId → user/playlist ---
  int? uid;
  try {
    final resp = await dio.get(
      'https://music.163.com/api/search/get/web',
      queryParameters: {'s': kw, 'type': 1000, 'limit': 1, 'offset': 0, 'total': 'true'},
      options: Options(headers: {'Referer': 'https://music.163.com/', 'User-Agent': ua}),
    );
    final root = _parse(resp) as Map?;
    final p = root?['result']?['playlists'];
    if (p is List && p.isNotEmpty) {
      final pl = p.first as Map;
      uid = pl['creator']?['userId'];
      print('[netease] 搜索歌单 creator.userId=$uid playlist=${pl['name']}');
    }
  } catch (err) {
    print('[netease 搜索歌单] 异常: $err');
  }
  if (uid != null) {
    try {
      final resp = await dio.get(
        'https://music.163.com/api/user/playlist',
        queryParameters: {'uid': uid, 'limit': 3, 'offset': 0},
        options: Options(headers: {'Referer': 'https://music.163.com/', 'User-Agent': ua}),
      );
      final root = _parse(resp) as Map?;
      print('[netease user/playlist] http=${resp.statusCode} code=${root?['code']}');
      final list = root?['playlist'];
      if (list is List && list.isNotEmpty) {
        final p = list.first as Map;
        _printObj('playlist[0] 关键字段', {
          'id': p['id'], 'name': p['name'], 'coverImgUrl': p['coverImgUrl'],
          'trackCount': p['trackCount'], 'userId': p['userId'],
          'creator': (p['creator'] as Map?)?['nickname'],
          'specialType': p['specialType'], 'subscribed': p['subscribed'],
        });
        print('  前3个: ${[for (final x in list.take(3)) (x as Map)['name']]}');
      }
    } catch (err) {
      print('[netease user/playlist] 异常: $err');
    }
  }

  // --- QQ：DoSearchForQQMusicDesktop songlist → creator → 用户歌单试探 ---
  try {
    final resp = await dio.post(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      data: jsonEncode({
        'music.search.SearchCgiService': {
          'method': 'DoSearchForQQMusicDesktop',
          'param': {'search_type': 'songlist', 'query': kw, 'page_num': 1, 'num_per_page': 2},
        },
      }),
      options: Options(contentType: 'application/json', headers: {
        'Referer': 'https://y.qq.com/', 'Origin': 'https://y.qq.com', 'User-Agent': ua}),
    );
    final root = _parse(resp) as Map?;
    final list = root?['music.search.SearchCgiService']?['data']?['body']?['songlist']?['list'];
    print('[qq songlist 搜索] list[0]:');
    if (list is List && list.isNotEmpty) _printObj('', list.first, 900);
  } catch (err) {
    print('[qq songlist 搜索] 异常: $err');
  }
}

// ---------- 详情端点：歌手热门歌曲 / 专辑歌曲 ----------

/// 深度优先找 Map 下第一个非空 List（酷狗各端点 list 键名不统一，用这个兜底）
List? _firstListUnder(Map m) {
  for (final v in m.values) {
    if (v is List && v.isNotEmpty) return v;
    if (v is Map) {
      final r = _firstListUnder(v);
      if (r != null) return r;
    }
  }
  return null;
}

/// 酷狗 android 签名 GET（公共参数 + 签名自动注入）
Future<Map?> _kugouSignedGet(Dio dio, String path,
    Map<String, String> params, Map<String, String> extraHeaders) async {
  final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final p = Map<String, String>.of(params);
  p['dfid'] = '-';
  p['mid'] = _randomMid();
  p['uuid'] = '-';
  p['appid'] = KugouLoginCrypto.appid;
  p['clientver'] = KugouLoginCrypto.clientver;
  p['clienttime'] = '$clienttime';
  p['signature'] = KugouLoginCrypto.androidSignature(p, '');
  final resp = await dio.get(
    'https://gateway.kugou.com$path',
    queryParameters: p,
    options: Options(headers: {
      'User-Agent': 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
      ...extraHeaders,
    }),
  );
  return _parse(resp) as Map?;
}

Future<void> _details(Dio dio) async {
  print('========== 详情端点：歌手热门歌曲 / 专辑歌曲 ==========');

  // ---------- 网易云 ----------
  int? neArtistId;
  String? neArtistName;
  try {
    final resp = await dio.get(
      'https://music.163.com/api/search/get/web',
      queryParameters: {'s': kw, 'type': 100, 'limit': 1, 'offset': 0, 'total': 'true'},
      options: Options(headers: {'Referer': 'https://music.163.com/', 'User-Agent': ua}),
    );
    final l = _parse(resp)?['result']?['artists'];
    if (l is List && l.isNotEmpty) {
      neArtistId = (l.first as Map)['id'] as int?;
      neArtistName = (l.first as Map)['name'] as String?;
    }
  } catch (err) {
    print('[netease 歌手搜索] 异常: $err');
  }
  if (neArtistId != null) {
    try {
      final resp = await dio.get('https://music.163.com/api/artist/$neArtistId',
          options: Options(
              headers: {'Referer': 'https://music.163.com/', 'User-Agent': ua}));
      final root = _parse(resp) as Map?;
      print('[netease artist/$neArtistId $neArtistName] http=${resp.statusCode} code=${root?['code']}');
      final hot = root?['hotSongs'];
      print('  hotSongs 长度: ${hot is List ? hot.length : hot}');
      if (hot is List && hot.isNotEmpty) {
        final s = hot.first as Map;
        _printObj('hotSongs[0] 关键字段', {
          'id': s['id'], 'name': s['name'],
          'artists': [for (final a in (s['artists'] as List? ?? const [])) (a as Map)['name']],
          'album': (s['album'] as Map?)?['name'],
          'duration': s['duration'], 'fee': s['fee'],
        }, 500);
      }
    } catch (err) {
      print('[netease artist] 异常: $err');
    }
  }
  int? neAlbumId;
  String? neAlbumName;
  try {
    final resp = await dio.get(
      'https://music.163.com/api/search/get/web',
      queryParameters: {'s': kw, 'type': 10, 'limit': 1, 'offset': 0, 'total': 'true'},
      options: Options(headers: {'Referer': 'https://music.163.com/', 'User-Agent': ua}),
    );
    final l = _parse(resp)?['result']?['albums'];
    if (l is List && l.isNotEmpty) {
      neAlbumId = (l.first as Map)['id'] as int?;
      neAlbumName = (l.first as Map)['name'] as String?;
    }
  } catch (err) {
    print('[netease 专辑搜索] 异常: $err');
  }
  if (neAlbumId != null) {
    // -462 是 web 端反爬：加 os=pc/appver cookie + /api/v1/album 重试
    const neHeaders = {
      'Referer': 'https://music.163.com/',
      'User-Agent': ua,
      'Cookie': 'os=pc; appver=10.0.0; navCtrl=',
    };
    for (final path in [
      'https://music.163.com/api/v1/album/$neAlbumId',
      'https://music.163.com/api/album/$neAlbumId',
    ]) {
      try {
        final resp = await dio.get(path, options: Options(headers: neHeaders));
        final root = _parse(resp) as Map?;
        print('[netease ${path.substring(path.indexOf('/api'))} $neAlbumId $neAlbumName] http=${resp.statusCode} code=${root?['code']}');
        final songs = root?['album']?['songs'] ?? root?['songs'];
        print('  songs 长度: ${songs is List ? songs.length : songs}');
        if (songs is List && songs.isNotEmpty) {
          final s = songs.first as Map;
          _printObj('songs[0] 关键字段', {
            'id': s['id'], 'name': s['name'],
            'artists': [for (final a in (s['artists'] as List? ?? const [])) (a as Map)['name']],
            'album': (s['album'] as Map?)?['name'],
            'duration': s['duration'], 'fee': s['fee'],
          }, 500);
          break;
        }
      } catch (err) {
        print('[netease album $path] 异常: $err');
      }
    }
  }

  // ---------- QQ ----------
  String? qqSingerMid;
  String? qqSingerName;
  try {
    final resp = await dio.get(
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp',
      queryParameters: {
        'p': 1, 'n': 1, 'w': kw, 't': 9,
        'format': 'json', 'inCharset': 'utf8', 'outCharset': 'utf-8',
      },
      options: Options(headers: {'Referer': 'https://y.qq.com/', 'User-Agent': ua}),
    );
    final l = _parse(resp)?['data']?['singer']?['list'];
    if (l is List && l.isNotEmpty) {
      qqSingerMid = (l.first as Map)['singerMID'] as String?;
      qqSingerName = (l.first as Map)['singerName'] as String?;
    }
  } catch (err) {
    print('[qq 歌手搜索] 异常: $err');
  }
  if (qqSingerMid != null && qqSingerMid.isNotEmpty) {
    // fcg_v8_singer_track_cp.fcg 已 404；上游 singer.get_songs_list 用
    // musichall.song_list_server.GetSingerSongList（musicu.fcg）
    try {
      final resp = await dio.post(
        'https://u.y.qq.com/cgi-bin/musicu.fcg',
        data: jsonEncode({
          'comm': {'ct': 24, 'cv': 0},
          'req_0': {
            'method': 'GetSingerSongList',
            'module': 'musichall.song_list_server',
            'param': {
              'singerMid': qqSingerMid, 'order': 1, 'number': 3, 'begin': 0,
            },
          },
        }),
        options: Options(contentType: 'application/json', headers: {
          'Referer': 'https://y.qq.com/', 'Origin': 'https://y.qq.com', 'User-Agent': ua}),
      );
      final root = _parse(resp) as Map?;
      final data = root?['req_0']?['data'];
      final list = data is Map ? (data['songList'] ?? data['song_list']) : null;
      print('[qq GetSingerSongList $qqSingerMid $qqSingerName] http=${resp.statusCode} code=${root?['req_0']?['code']}');
      print('  songList 长度: ${list is List ? list.length : list}');
      if (list is List && list.isNotEmpty) {
        final item = list.first;
        if (item is Map) {
          final s = item['songInfo'] ?? item;
          if (s is Map) {
            final song = s['song'] ?? s;
            _printObj('songList[0] 关键字段', {
              'mid': song['mid'], 'name': song['name'],
              'singer': [for (final x in (song['singer'] as List? ?? const [])) (x as Map)['name']],
              'album': (song['album'] as Map?)?['name'],
              'interval': song['interval'],
            }, 500);
          }
        }
      }
    } catch (err) {
      print('[qq GetSingerSongList] 异常: $err');
    }
  }
  String? qqAlbumMid;
  String? qqAlbumName;
  try {
    final resp = await dio.get(
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp',
      queryParameters: {
        'p': 1, 'n': 1, 'w': kw, 't': 8,
        'format': 'json', 'inCharset': 'utf8', 'outCharset': 'utf-8',
      },
      options: Options(headers: {'Referer': 'https://y.qq.com/', 'User-Agent': ua}),
    );
    final l = _parse(resp)?['data']?['album']?['list'];
    if (l is List && l.isNotEmpty) {
      qqAlbumMid = (l.first as Map)['albumMID'] as String?;
      qqAlbumName = (l.first as Map)['albumName'] as String?;
    }
  } catch (err) {
    print('[qq 专辑搜索] 异常: $err');
  }
  if (qqAlbumMid != null && qqAlbumMid.isNotEmpty) {
    try {
      final resp = await dio.post(
        'https://u.y.qq.com/cgi-bin/musicu.fcg',
        data: jsonEncode({
          'comm': {'ct': 24, 'cv': 0},
          'req_0': {
            'method': 'GetAlbumSongList',
            'module': 'music.musichallAlbum.AlbumSongList',
            'param': {'albumMid': qqAlbumMid, 'begin': 0, 'num': 3},
          },
        }),
        options: Options(contentType: 'application/json', headers: {
          'Referer': 'https://y.qq.com/', 'Origin': 'https://y.qq.com', 'User-Agent': ua}),
      );
      final root = _parse(resp) as Map?;
      final list = root?['req_0']?['data']?['songList'];
      print('[qq AlbumSongList $qqAlbumMid $qqAlbumName] http=${resp.statusCode} code=${root?['req_0']?['code']}');
      print('  songList 长度: ${list is List ? list.length : list}');
      if (list is List && list.isNotEmpty) {
        final item = list.first as Map;
        final s = item['songInfo'];
        final song = s is Map ? s['song'] : null;
        if (song is Map) {
          _printObj('songList[0].songInfo.song 关键字段', {
            'mid': song['mid'], 'name': song['name'],
            'singer': [for (final x in (song['singer'] as List? ?? const [])) (x as Map)['name']],
            'album': (song['album'] as Map?)?['name'],
            'interval': song['interval'],
          }, 500);
        } else {
          _printObj('songList[0]', item, 600);
        }
      }
    } catch (err) {
      print('[qq AlbumSongList] 异常: $err');
    }
  }

  // ---------- 酷狗 ----------
  String? kgAuthorId;
  String? kgAuthorName;
  try {
    final root = await _kugouSignedGet(dio, '/v1/search/author', {
      'keyword': kw, 'page': '1', 'pagesize': '1',
      'platform': 'AndroidFilter', 'iscorrection': '1',
    }, {'x-router': 'complexsearch.kugou.com'});
    final data = root?['data'];
    final l = data is Map ? _firstListUnder(data) : null;
    if (l != null && l.isNotEmpty) {
      final m = l.first as Map;
      kgAuthorId = '${m['AuthorId'] ?? m['author_id'] ?? ''}';
      kgAuthorName = '${m['AuthorName'] ?? m['author_name'] ?? ''}';
    }
    print('[kugou 歌手搜索] AuthorId=$kgAuthorId AuthorName=$kgAuthorName');
  } catch (err) {
    print('[kugou 歌手搜索] 异常: $err');
  }
  if (kgAuthorId != null && kgAuthorId.isNotEmpty) {
    try {
      final root = await _kugouSignedGet(dio, '/openapi/kmr/v2/audio_group/author', {
        'author_id': kgAuthorId, 'area_code': 'all', 'sort': '1',
        'page': '1', 'pagesize': '3', 'replace_api_version': '1',
        'mvdata_need': '1', 'show_audio_honor': '1', 'show_audio_tag': '1',
        'replace_need': '1',
      }, {'kg-tid': '36'});
      print('[kugou author_audios $kgAuthorId $kgAuthorName]');
      if (root == null) {
        print('  解析失败');
      } else {
        print('  status=${root['status']} error_code=${root['error_code']}');
        final data = root['data'];
        if (data is Map) {
          print('  data.keys=${data.keys.toList()}');
          final l = _firstListUnder(data);
          print('  首个 list 长度: ${l?.length}');
          if (l != null && l.isNotEmpty) {
            _printObj('  list[0]', l.first, 3000);
            final first = l.first;
            if (first is Map) {
              print('  list[0].keys: ${first.keys.toList()}');
            }
          }
        } else {
          _printObj('root', root, 600);
        }
      }
    } catch (err) {
      print('[kugou author_audios] 异常: $err');
    }
  }
  String? kgAlbumId;
  String? kgAlbumName;
  try {
    final root = await _kugouSignedGet(dio, '/v1/search/album', {
      'keyword': kw, 'page': '1', 'pagesize': '1',
      'platform': 'AndroidFilter', 'iscorrection': '1',
      'category': '1', 'sorttype': '0', 'searchsong': '0',
    }, {'x-router': 'complexsearch.kugou.com'});
    final data = root?['data'];
    final l = data is Map ? _firstListUnder(data) : null;
    if (l != null && l.isNotEmpty) {
      final m = l.first as Map;
      kgAlbumId = '${m['albumid'] ?? m['AlbumID'] ?? ''}';
      kgAlbumName = '${m['albumname'] ?? m['AlbumName'] ?? ''}';
    }
    print('[kugou 专辑搜索] albumid=$kgAlbumId albumname=$kgAlbumName');
  } catch (err) {
    print('[kugou 专辑搜索] 异常: $err');
  }
  if (kgAlbumId != null && kgAlbumId.isNotEmpty) {
    try {
      final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final body = jsonEncode(<String, dynamic>{
        'album_id': kgAlbumId, 'is_buy': '', 'page': 1, 'pagesize': 3,
      });
      final params = <String, String>{
        'dfid': '-', 'mid': _randomMid(), 'uuid': '-',
        'appid': KugouLoginCrypto.appid,
        'clientver': KugouLoginCrypto.clientver,
        'clienttime': '$clienttime',
      };
      params['signature'] = KugouLoginCrypto.androidSignature(params, body);
      final resp = await dio.post(
        'https://gateway.kugou.com/v1/album_audio/lite',
        queryParameters: params,
        data: body,
        options: Options(
          contentType: 'application/json',
          headers: {
            'x-router': 'openapi.kugou.com',
            'kg-tid': '255',
            'User-Agent': 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
          },
        ),
      );
      final root = _parse(resp) as Map?;
      print('[kugou album_audio/lite $kgAlbumId $kgAlbumName] http=${resp.statusCode}');
      if (root == null) {
        print('  解析失败');
      } else {
        print('  status=${root['status']} error_code=${root['error_code']}');
        final data = root['data'];
        if (data is Map) {
          print('  data.keys=${data.keys.toList()}');
          final l = _firstListUnder(data);
          print('  首个 list 长度: ${l?.length}');
          if (l != null && l.isNotEmpty) {
            _printObj('  list[0]', l.first, 3000);
            final first = l.first;
            if (first is Map) {
              print('  list[0].keys: ${first.keys.toList()}');
            }
          }
        } else {
          _printObj('root', root, 600);
        }
      }
    } catch (err) {
      print('[kugou album_audio/lite] 异常: $err');
    }
  }
}

String _randomMid() {
  final rng = Random();
  return String.fromCharCodes(
      List<int>.generate(40, (_) => 48 + rng.nextInt(10)));
}
