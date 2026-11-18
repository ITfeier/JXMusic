import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';
import '../../models/song.dart';
import '../../models/playlist.dart';
import '../../models/artist.dart';
import '../../models/album.dart';
import '../../models/lyric_hit.dart';
import 'music_api.dart';
import 'http.dart';
import 'netease_crypto.dart';

/// 从 `/api/song/detail` 响应里解析 `id -> 封面 URL` 映射（纯函数，便于单测）。
///
/// 公开搜索接口 `album` 只有 `picId` 没有 `picUrl`，所以搜索后用 detail 接口补；
/// detail 的字段是 `songs[].album.picUrl`（个别版本是 `al.picUrl` / `blurPicUrl`）。
/// 结构异常时返回空映射，不抛异常。
Map<String, String> neteaseCoversFromDetailJson(Object? raw) {
  final covers = <String, String>{};
  try {
    final data = raw is Map ? raw : null;
    final songs = data?['songs'];
    if (songs is! List) return covers;
    for (final item in songs) {
      if (item is! Map) continue;
      final id = '${item['id'] ?? ''}';
      if (id.isEmpty) continue;
      final album = item['album'] ?? item['al'];
      final pic =
          album is Map ? (album['picUrl'] ?? album['blurPicUrl']) : null;
      final url = jxNormalizeImageUrl(pic is String ? pic : null);
      if (url.isNotEmpty) covers[id] = url;
    }
  } catch (_) {
    // 结构异常按“没有补到封面”处理，不影响搜索主流程
  }
  return covers;
}

/// 把 detail 接口补到的封面按 id 回填到搜索结果（纯函数）：
/// 只补 `coverUrl` 为空的歌，已有封面的不覆盖；返回新列表，不修改入参。
List<Song> neteaseFillMissingCovers(
  List<Song> songs,
  Map<String, String> covers,
) {
  if (covers.isEmpty) return List<Song>.of(songs);
  return [
    for (final s in songs)
      if (s.coverUrl.isEmpty && (covers[s.id] ?? '').isNotEmpty)
        s.copyWith(coverUrl: covers[s.id])
      else
        s,
  ];
}

/// 需要补封面的歌曲 id 分片（detail 接口单次最多 100 个 id）：
/// 去重、跳过空 id，按顺序切成每片不超过 [max] 个。
List<List<String>> neteaseCoverIdChunks(
  Iterable<String> ids, {
  int max = 100,
}) {
  final unique = <String>[];
  final seen = <String>{};
  for (final id in ids) {
    if (id.isEmpty) continue;
    if (seen.add(id)) unique.add(id);
  }
  final chunks = <List<String>>[];
  for (var i = 0; i < unique.length; i += max) {
    chunks.add(unique.sublist(i, math.min(i + max, unique.length)));
  }
  return chunks;
}

/// 网易云搜索结果 -> Song（兼容 `/api/search/get/web` 与 weapi cloudsearch 两种字段）
///
/// 公开接口字段：`artists[]`、`album{}`、`duration(ms)`、`fee`；
/// weapi 字段：`ar[]`、`al{}`、`dt(ms)`、`fee`。
/// fee：0 免费、1 VIP、4 付费专辑、8 非会员可试听低音质。
Song? neteaseSongFromSearchJson(Object? raw) {
  if (raw is! Map) return null;
  try {
    final m = Map<String, dynamic>.from(raw);
    final artists = (m['ar'] as List? ?? m['artists'] as List? ?? [])
        .whereType<Map>()
        .map((a) => a['name'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .join('、');
    final album = (m['al'] as Map?) ?? (m['album'] as Map?);
    final fee = (m['fee'] as num?)?.toInt() ?? 0;
    final durationMs = (m['dt'] as num?)?.toInt() ??
        (m['duration'] as num?)?.toInt() ??
        0;
    return Song(
      id: '${m['id'] ?? ''}',
      platform: 1,
      title: m['name'] as String? ?? '',
      artist: artists.isEmpty ? '未知歌手' : artists,
      album: album?['name'] as String? ?? '',
      coverUrl: jxNormalizeImageUrl(
          (album?['picUrl'] ?? album?['blurPicUrl']) as String?),
      duration: durationMs ~/ 1000,
      vip: fee == 1 || fee == 4,
    );
  } catch (_) {
    return null;
  }
}

/// 网易云音乐接口（基于公开逆向 webapi）
class NeteaseApi implements MusicPlatformApi {
  @override
  int get platform => 1;

  /// 最近一次扫码操作的具体失败原因（等待/成功时为 null；设置页据此展示准确提示）
  String? _lastError;

  @override
  String? get lastError => _lastError;

  // 公开 webapi 接口（无登录态基础能力）
  static const String _base = 'https://music.163.com/api';
  static const String _baseWeb = 'https://music.163.com/weapi';
  static const String _musicBase = 'https://music.163.com';

  Map<String, String> _cookies = {};

  /// 扫码链路诊断日志（debugPrint 在 lib 里不便直接依赖 Flutter，
  /// 用 print + ignore 保证 `dart run tool/*` 仍可执行；Android 上
  /// `adb logcat -s flutter` 可抓到）。日志里不输出完整 cookie/token。
  void _log(String message) {
    // ignore: avoid_print
    print('[JXMusic][网易云登录] $message');
  }

  /// 打码：只保留前 [head] 后 [tail] 个字符，短值只输出长度
  static String _mask(String? value, {int head = 4, int tail = 4}) {
    if (value == null || value.isEmpty) return '(空)';
    if (value.length <= head + tail) return 'len=${value.length}';
    return '${value.substring(0, head)}…${value.substring(value.length - tail)}'
        '(len=${value.length})';
  }

  static String _short(Object? value, [int max = 200]) {
    final s = '${value ?? ''}';
    return s.length <= max ? s : '${s.substring(0, max)}…(len=${s.length})';
  }

  /// 兼容 code 为数字或字符串（服务端不同版本返回类型不一致）
  static int _codeOf(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? -1;
    return -1;
  }

  /// 网络异常 -> 用户可读原因
  static String _describeError(Object error, String prefix) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code != null) return '$prefix：HTTP $code';
      return '$prefix：网络不可达（${error.type.name}）';
    }
    return '$prefix：$error';
  }

  /// 合并响应头里的 Set-Cookie（803 成功时 MUSIC_U 在响应头，不在响应体）。
  ///
  /// 与 qq_api 保持一致：**忽略值为空的 Set-Cookie**（删除 cookie 指令），
  /// 避免同名清空行覆盖已拿到的有效值（如 MUSIC_U / __csrf）。
  void _collectSetCookies(Headers headers, Map<String, String> into) {
    final list = headers['set-cookie'];
    if (list == null) return;
    for (final item in list) {
      final seg = item.split(';').first.trim();
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final name = seg.substring(0, eq).trim();
      final value = seg.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      into[name] = value;
    }
  }

  @override
  Future<List<Song>> searchSongs(String keyword,
      {int page = 1, int size = 30}) async {
    final offset = (page - 1) * size;
    // 优先用当前可用的公开搜索接口（2026-11 实测 /api/cloudsearch/pc/search/get 已 404）；
    // 失败时再退回 weapi 版本（若官方恢复可用）。
    try {
      final resp = await JXHttp.dio.get(
        '$_musicBase/api/search/get/web',
        queryParameters: {
          's': keyword,
          'type': 1,
          'limit': size,
          'offset': offset,
          'total': 'true',
        },
      );
      final data = resp.data;
      final result = data is Map ? data['result'] : null;
      final songs = (result is Map ? result['songs'] as List? : null) ?? const [];
      final list = songs
          .map<Song?>((s) => neteaseSongFromSearchJson(s))
          .whereType<Song>()
          .toList();
      if (list.isNotEmpty) return await _fillMissingCovers(list);
    } catch (_) {}

    try {
      final data = {
        's': keyword,
        'type': 1,
        'limit': size,
        'offset': offset,
        'total': true,
      };
      final resp = await _weapi('/api/cloudsearch/pc/search/get', data);
      final result = resp['result'] as Map<String, dynamic>?;
      final songs = (result?['songs'] as List?) ?? const [];
      final list = songs
          .map<Song?>((s) => neteaseSongFromSearchJson(s))
          .whereType<Song>()
          .toList();
      return await _fillMissingCovers(list);
    } catch (e) {
      return const [];
    }
  }

  /// 搜索结果批量补封面：`/api/search/get/web` 的 album 只有 picId、没有 picUrl，
  /// 导致封面为空。这里走 `/api/song/detail?ids=[...]` 拿 `songs[].album.picUrl`，
  /// 按 id 只回填空封面；任何一片失败都静默跳过，不影响搜索本身。
  Future<List<Song>> _fillMissingCovers(List<Song> songs) async {
    if (songs.isEmpty) return songs;
    final chunks = neteaseCoverIdChunks(
      songs.where((s) => s.coverUrl.isEmpty).map((s) => s.id),
    );
    if (chunks.isEmpty) return songs;
    final covers = <String, String>{};
    for (final chunk in chunks) {
      try {
        // ids 是 JSON 数组；能转数字的用数字（与公开接口一致），其余保持字符串。
        final ids = jsonEncode(
          chunk.map<Object>((id) => int.tryParse(id) ?? id).toList(),
        );
        final resp = await JXHttp.dio.get(
          '$_base/song/detail',
          queryParameters: {'ids': ids},
          // 补封面是锦上添花：给更短的超时，避免拖慢搜索列表。
          options: Options(receiveTimeout: const Duration(seconds: 8)),
        );
        covers.addAll(neteaseCoversFromDetailJson(resp.data));
      } catch (_) {
        // detail 失败：保持原 coverUrl 为空，交给 UI 渐变占位
      }
    }
    return neteaseFillMissingCovers(songs, covers);
  }

  String _cover(String? url) => jxNormalizeImageUrl(url);

  @override
  Future<String?> getPlayUrl(Song song) async {
    final sid = int.tryParse(song.id);
    if (sid == null) return null;

    // 1) 公开 GET 接口：不需要 weapi 加密，免费/低价歌曲可直接拿直链
    //    （2026-11 实测：fee=0/8 返回 200 + url；VIP fee=1 返回 code=-110 需登录）
    //    登录后带上 MUSIC_U 等会话 cookie（只发 music.163.com 官方域），
    //    否则 VIP 歌曲仍按未登录处理。
    // 先请求 320kbps：免费/低价歌曲通常直接返回高音质直链；拿不到再降 128k
    // （原来 128k 在前导致所有网易云歌曲永久锁死在 128kbps）。
    for (final br in const [320000, 128000]) {
      try {
        final resp = await JXHttp.dio.get(
          '$_base/song/enhance/player/url',
          queryParameters: {'ids': '[$sid]', 'br': br},
          options: Options(headers: {
            if (_cookies.isNotEmpty) 'Cookie': _cookieStr(),
            'Referer': 'https://music.163.com/',
          }),
        );
        final data = resp.data;
        final list = data is Map ? data['data'] as List? : null;
        if (list == null || list.isEmpty) continue;
        final first = list.first;
        if (first is! Map) continue;
        final url = first['url'] as String?;
        if (url != null && url.isNotEmpty) return url;
      } catch (_) {}
    }

    // 2) weapi 兜底（老接口，登录后更可能返回高音质）
    try {
      final data = {
        'ids': jsonEncode([sid]),
        'level': 'standard',
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
    // 1) 公开 GET 接口（2026-11 实测可用）
    try {
      final resp = await JXHttp.dio.get(
        '$_base/song/lyric',
        queryParameters: {
          'id': song.id,
          'lv': -1,
          'kv': -1,
          'tv': -1,
        },
        options: Options(headers: {
          // 已登录时附 MUSIC_U 等会话 cookie（只发 music.163.com 官方域）；
          // 未登录时保持公开 GET 行为不变（PRD R1.2）。
          if (_cookies.isNotEmpty) 'Cookie': _cookieStr(),
          'Referer': 'https://music.163.com/',
        }),
      );
      final data = resp.data;
      final lrc = data is Map ? data['lrc'] : null;
      final text = (lrc is Map ? lrc['lyric'] as String? : null) ?? '';
      if (text.isNotEmpty) return text;
    } catch (_) {}

    // 2) weapi 兜底
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
      // 必须带登录 Cookie：隐私歌单（privacy>0）匿名请求会被 401
      // 「该歌单已被创建者设置为隐私」拒绝（探针实测：带会话 200 全量）
      final resp = await JXHttp.dio.get('$_base/v3/playlist/detail',
          queryParameters: {'id': playlist.id, 'n': '1000'},
          options: Options(headers: {
            'Cookie': _cookieStr(),
            'Referer': 'https://music.163.com/',
          }));
      final detail = resp.data['playlist'] as Map<String, dynamic>?;
      var tracks = (detail?['tracks'] as List?) ?? [];
      if (_probe && tracks.isEmpty) {
        // ignore: avoid_print
        print('[probe] netease v3/playlist/detail tracks empty, '
            'id=${playlist.id} status=${resp.statusCode} '
            'body=${jsonEncode(resp.data).substring(0, jsonEncode(resp.data).length > 500 ? 500 : jsonEncode(resp.data).length)}');
      }
      // v3 接口不支持服务端分页：page>1 时本地切片兑现分页契约；
      // page=1 保持全量返回（歌单详情页按全量展示/整单入队，不能截断）。
      if (page > 1) {
        tracks = tracks.skip((page - 1) * size).take(size).toList();
      }
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

  // ---- 登录账号歌单（/api/nuser/account/get 拿 uid → /api/user/playlist）----

  /// 探针开关：`dart run -DJX_PROBE=true` 时打印账号歌单原始响应，
  /// 正常构建（含 release）编译期剔除。
  static const bool _probe = bool.fromEnvironment('JX_PROBE');

  @override
  Future<List<Playlist>> userPlaylists(
      {int page = 1, int size = 30}) async {
    // 未登录直接空结果（user/playlist 必须带 MUSIC_U 会话）
    if ((_cookies['MUSIC_U'] ?? '').isEmpty) return const [];
    try {
      // 老版 web 接口 /api/nuser/account/get：带 MUSIC_U 返回
      // account+profile；profile 为 null 即会话已失效（探针实测：
      // 错误路径 /api/user/account 会返回 404「接口未找到」）
      final acct = await JXHttp.dio.get('$_base/nuser/account/get',
          options: Options(headers: {
            'Cookie': _cookieStr(),
            'Referer': 'https://music.163.com/',
          }));
      final acctData = acct.data;
      final profile = acctData is Map ? acctData['profile'] : null;
      final uid = profile is Map ? profile['userId'] : null;
      if (uid == null) {
        if (_probe) {
          // ignore: avoid_print
          print('[probe] netease user/account profile null, '
              'status=${acct.statusCode} body=${jsonEncode(acctData)}');
        }
        // 已带 MUSIC_U 但拿不到用户：会话已失效，须与「0 个歌单」区分开
        throw const SessionExpiredException('登录已过期，请重新登录');
      }
      if (_probe) {
        // ignore: avoid_print
        print('[probe] netease user/account ok, uid=$uid');
      }
      final resp = await JXHttp.dio.get('$_base/user/playlist',
          queryParameters: {
            'uid': uid,
            'limit': size,
            'offset': (page - 1) * size,
          },
          options: Options(headers: {
            'Cookie': _cookieStr(),
            'Referer': 'https://music.163.com/',
          }));
      // 老接口 /api/user/playlist 的响应字段是单数 "playlist"
      // （探针实测：{"more":false,"playlist":[...],"code":200}），
      // 新版 weapi 才是 "playlists"，两者都兜住
      final list = (resp.data['playlist'] as List?) ??
          (resp.data['playlists'] as List?) ??
          const [];
      if (_probe && list.isEmpty) {
        // ignore: avoid_print
        print('[probe] netease user/playlist empty, '
            'uid=$uid status=${resp.statusCode} '
            'body=${jsonEncode(resp.data)}');
      }
      return list.map<Playlist>((p) {
        final m = p as Map<String, dynamic>;
        return Playlist(
          id: '${m['id'] ?? ''}',
          platform: platform,
          title: m['name'] as String? ?? '',
          coverUrl: jxNormalizeImageUrl(m['coverImgUrl'] as String?),
          creator: (m['creator'] as Map?)?['nickname'] as String? ?? '',
          songCount: (m['trackCount'] as num?)?.toInt() ?? 0,
        );
      }).where((p) => p.id.isNotEmpty).toList();
    } on SessionExpiredException {
      rethrow;
    } catch (_) {
      return const [];
    }
  }

  // ---- 分类搜索（/api/search/get/web，type=1000/100/10/1006；2026-11 探针实测）----

  @override
  Future<List<Playlist>> searchPlaylists(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final resp = await JXHttp.dio.get(
        '$_musicBase/api/search/get/web',
        queryParameters: {
          's': keyword, 'type': 1000, 'limit': size,
          'offset': (page - 1) * size, 'total': 'true',
        },
      );
      final list = (resp.data['result']?['playlists'] as List?) ?? const [];
      return list.map<Playlist>((p) {
        final m = p as Map<String, dynamic>;
        return Playlist(
          id: '${m['id'] ?? ''}',
          platform: platform,
          title: m['name'] as String? ?? '',
          coverUrl: jxNormalizeImageUrl(m['coverImgUrl'] as String?),
          creator: (m['creator'] as Map?)?['nickname'] as String? ?? '',
          songCount: (m['trackCount'] as num?)?.toInt() ?? 0,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Artist>> searchArtists(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final resp = await JXHttp.dio.get(
        '$_musicBase/api/search/get/web',
        queryParameters: {
          's': keyword, 'type': 100, 'limit': size,
          'offset': (page - 1) * size, 'total': 'true',
        },
      );
      final list = (resp.data['result']?['artists'] as List?) ?? const [];
      return list.map<Artist>((a) {
        final m = a as Map<String, dynamic>;
        return Artist(
          id: '${m['id'] ?? ''}',
          platform: platform,
          name: m['name'] as String? ?? '',
          avatarUrl: jxNormalizeImageUrl(
              m['img1v1Url'] as String? ?? m['picUrl'] as String?),
          albumCount: (m['albumSize'] as num?)?.toInt() ?? 0,
          songCount: (m['musicSize'] as num?)?.toInt() ?? 0,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Album>> searchAlbums(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final resp = await JXHttp.dio.get(
        '$_musicBase/api/search/get/web',
        queryParameters: {
          's': keyword, 'type': 10, 'limit': size,
          'offset': (page - 1) * size, 'total': 'true',
        },
      );
      final list = (resp.data['result']?['albums'] as List?) ?? const [];
      return list.map<Album>((a) {
        final m = a as Map<String, dynamic>;
        return Album(
          id: '${m['id'] ?? ''}',
          platform: platform,
          name: m['name'] as String? ?? '',
          coverUrl: jxNormalizeImageUrl(m['picUrl'] as String?),
          artist: (m['artist'] as Map?)?['name'] as String? ?? '',
          songCount: (m['size'] as num?)?.toInt() ?? 0,
          publishTime: _neteasePublishDate(m['publishTime']),
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 毫秒时间戳 → 'yyyy-MM-dd'（解析失败返回空串）
  static String _neteasePublishDate(Object? ts) {
    final ms = (ts as num?)?.toInt();
    if (ms == null || ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Future<List<LyricHit>> searchLyrics(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final resp = await JXHttp.dio.get(
        '$_musicBase/api/search/get/web',
        queryParameters: {
          's': keyword, 'type': 1006, 'limit': size,
          'offset': (page - 1) * size, 'total': 'true',
        },
      );
      final list = (resp.data['result']?['songs'] as List?) ?? const [];
      final hits = <LyricHit>[];
      for (final item in list) {
        final m = item as Map<String, dynamic>;
        final song = neteaseSongFromSearchJson(m);
        if (song == null) continue;
        // 命中片段可能带 <b>关键词</b> 高亮标签，展示前清掉
        final fragments = (m['lyrics'] as List? ?? const [])
            .whereType<String>()
            .map((s) => s.replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '').trim())
            .where((s) => s.isNotEmpty)
            .toList();
        hits.add(LyricHit(song: song, snippet: fragments.join(' ')));
      }
      if (hits.isEmpty) return hits;
      // 歌词搜索结果不带专辑封面：与歌曲搜索同款 detail 补封面
      final filled = await _fillMissingCovers(
          hits.map((h) => h.song).toList(growable: false));
      return [
        for (var i = 0; i < hits.length; i++)
          LyricHit(song: filled[i], snippet: hits[i].snippet),
      ];
    } catch (_) {
      return const [];
    }
  }

  // ---- 歌手热门歌曲 / 专辑歌曲（详情页数据源）----

  @override
  Future<List<Song>> artistSongs(Artist artist,
      {int page = 1, int size = 30}) async {
    if (artist.id.isEmpty) return const [];
    try {
      // /api/artist/{id}：hotSongs 固定 50 首（2026-11 探针实测），
      // 不支持服务端分页，page>1 时本地切片兑现分页契约。
      final resp = await JXHttp.dio.get(
        '$_musicBase/api/artist/${artist.id}',
        queryParameters: {'limit': size, 'offset': (page - 1) * size},
      );
      var hot = (resp.data['hotSongs'] as List?) ?? const [];
      if (page > 1) hot = hot.skip((page - 1) * size).toList();
      return hot
          .take(size)
          .map<Song?>((s) => neteaseSongFromSearchJson(s))
          .whereType<Song>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Song>> albumSongs(Album album,
      {int page = 1, int size = 30}) async {
    if (album.id.isEmpty) return const [];
    try {
      // /api/album/{id} 需带 os=pc cookie（探针实测不带会 -462 反爬）
      final resp = await JXHttp.dio.get(
        '$_musicBase/api/album/${album.id}',
        options: Options(headers: {
          'Cookie': 'os=pc; appver=10.0.0;',
          'Referer': 'https://music.163.com/',
        }),
      );
      var songs = (resp.data['album']?['songs'] as List?) ?? const [];
      // 专辑歌曲一次返回全量：page>1 时本地切片兑现分页契约。
      if (page > 1) songs = songs.skip((page - 1) * size).toList();
      return songs
          .take(size)
          .map<Song?>((s) => neteaseSongFromSearchJson(s))
          .whereType<Song>()
          .toList();
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
      var tracks = (resp.data['playlist']['tracks'] as List?) ?? [];
      // 榜单接口一次返回全部：page>1 时本地偏移兑现分页契约。
      if (page > 1) tracks = tracks.skip((page - 1) * size).toList();
      return tracks.take(size).map<Song>((s) {
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

  // ---- 扫码登录（eapi 协议；2026-11 真机实扫：web 模拟会被 8821 拒绝）----
  //
  // 真机实扫证据（2026-11-09）：手机确认后旧 /api 链路返回
  // `code=8821 message=请切换其他登录方式或升级新版本再试`。官方已拒绝
  // 「web 模拟」扫码，必须按官方客户端形态请求（参考实现：
  // Yuanlang3/dsh-netease-music-plugin lib/index.js 的 eapiPost/qr-key/qr-check）：
  //   · POST /eapi/login/qrcode/unikey、/eapi/login/qrcode/client/login
  //   · body: params=<AES-128-ECB 明文 hex 大写>，明文 =
  //     apiPath-36cd479b6b5-json-36cd479b6b5-md5(
  //     'nobody'+apiPath+'use'+json+'md5forencrypt')，apiPath **不含 /eapi**
  //   · 请求头带官方客户端 UA + os/appver/deviceId 等 Cookie
  //     （unikey 与 poll 必须同一个 deviceId）
  //   · data.type = "3"；二维码内容仍为 https://music.163.com/login?codekey=<unikey>
  static const String _eapiKey = 'e82ckenh8dichen8';
  static const String _eapiUa =
      'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)';
  static const String _eapiUnikeyPath = '/api/login/qrcode/unikey';
  static const String _eapiCheckPath = '/api/login/qrcode/client/login';

  /// 本次二维码登录的设备指纹（unikey 与 poll 共用）
  String? _qrDeviceId;

  /// 扫码进度提示（801 等待 / 802 已扫待确认），非错误；供设置页展示
  String? _qrHint;
  String? get qrHint => _qrHint;

  static String _md5Hex(String text) =>
      md5.convert(utf8.encode(text)).toString();

  /// AES-128-ECB + PKCS7，输出**大写** hex（与官方 eapi 一致）
  static String _aesEcbHex(String plainText) {
    final cipher = ECBBlockCipher(AESEngine())
      ..init(true, KeyParameter(Uint8List.fromList(utf8.encode(_eapiKey))));
    final data = Uint8List.fromList(utf8.encode(plainText));
    final pad = 16 - (data.length % 16);
    final padded = Uint8List(data.length + pad)..setRange(0, data.length, data);
    for (var i = data.length; i < padded.length; i++) {
      padded[i] = pad;
    }
    final out = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += 16) {
      cipher.processBlock(padded, offset, out, offset);
    }
    return out
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  }

  /// eapi 加密：返回 params 明文 hex（公开静态方法，便于单测固定向量断言）
  static String eapiParams(String apiPath, Map<String, dynamic> data) {
    final text = jsonEncode(data);
    final digest = _md5Hex('nobody${apiPath}use${text}md5forencrypt');
    return _aesEcbHex('$apiPath-36cd479b6b5-$text-36cd479b6b5-$digest');
  }

  static String _randomDeviceId() {
    final rng = math.Random.secure();
    const chars = '0123456789ABCDEF';
    return List<String>.generate(52, (_) => chars[rng.nextInt(16)]).join();
  }

  /// 官方客户端指纹 Cookie（key/value 都 URI 编码；每次请求刷新 requestId/buildver）
  static String _qrCookieHeader(String deviceId) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final requestId =
        '${nowMs}_${math.Random().nextInt(1000).toString().padLeft(4, '0')}';
    final header = <String, String>{
      'osver': 'Microsoft-Windows-10-Professional-build-19045-64bit',
      'deviceId': deviceId,
      'os': 'pc',
      'appver': '3.1.17.204416',
      'versioncode': '140',
      'mobilename': '',
      'buildver': '${nowMs ~/ 1000}',
      'resolution': '1920x1080',
      '__csrf': '',
      'channel': 'netease',
      'requestId': requestId,
    };
    return header.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('; ');
  }

  /// eapi POST：URL 用 /eapi 前缀，加密用 /api 路径
  Future<Response<dynamic>> _eapiPost(
      String apiPath, Map<String, dynamic> data, String deviceId) {
    final url = '$_musicBase${apiPath.replaceFirst('/api/', '/eapi/')}';
    return JXHttp.dio.post(url,
        data: {'params': eapiParams(apiPath, data)},
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'User-Agent': _eapiUa,
            'Cookie': _qrCookieHeader(deviceId),
            'Referer': 'https://music.163.com/',
          },
        ));
  }

  @override
  Future<({String qrUrl, String key})> createQrLogin() async {
    _lastError = null;
    _qrHint = null;
    final deviceId = _randomDeviceId();
    _qrDeviceId = deviceId;
    try {
      final resp = await _eapiPost(_eapiUnikeyPath, {'type': '3'}, deviceId);
      final data = resp.data is Map ? resp.data as Map : const {};
      final key = '${data['unikey'] ?? ''}'.trim();
      _log('eapi 取码 HTTP=${resp.statusCode} code=${data['code']} '
          'unikey=${_mask(key)} deviceId=${_mask(deviceId)} '
          'set-cookie=[${_cookieNames(resp.headers)}]');
      if (resp.statusCode != 200 || key.isEmpty || key == 'null') {
        _lastError = '网易云取码失败（HTTP ${resp.statusCode}，响应缺少 unikey'
            '${data['message'] == null ? '' : '：${data['message']}'}）';
        _log(_lastError!);
        return (qrUrl: '', key: '');
      }
      return (qrUrl: 'https://music.163.com/login?codekey=$key', key: key);
    } catch (e) {
      _lastError = _describeError(e, '网易云二维码获取失败');
      _log('取码异常：$_lastError');
      return (qrUrl: '', key: '');
    }
  }

  @override
  Future<AccountSession?> pollQrLogin(String key) async {
    if (key.isEmpty) return null;
    final deviceId = _qrDeviceId ?? _randomDeviceId();
    _qrDeviceId = deviceId;
    try {
      final resp =
          await _eapiPost(_eapiCheckPath, {'key': key, 'type': '3'}, deviceId);
      final data = resp.data is Map ? resp.data as Map : const {};
      final code = _codeOf(data['code']);
      final message = '${data['message'] ?? data['msg'] ?? ''}'.trim();
      _log('eapi 轮询 HTTP=${resp.statusCode} code=$code'
          '${message.isEmpty ? '' : ' message=$message'} '
          'set-cookie=[${_cookieNames(resp.headers)}]');
      switch (code) {
        case 801: // 等待扫码
          _qrHint = null;
          _lastError = null;
          return null;
        case 802: // 已扫码，等待手机端确认/授权中
          _qrHint = '已扫码，请在手机上确认登录';
          _lastError = null;
          return null;
        case 800: // 二维码过期
          _qrHint = null;
          _lastError = '二维码已过期，请关闭后重新获取';
          return null;
        case 8821: // 风控 / 协议不符（2026-11 真机实扫出现过）
          _qrHint = null;
          _lastError = '账号或网络触发风控（code 8821），请稍后重试或更换网络';
          return null;
        case 803: // 登录成功
          break;
        default:
          _qrHint = null;
          _lastError = '网易云扫码登录失败（HTTP ${resp.statusCode}，code=$code'
              '${message.isEmpty ? '' : '，${_short(message, 120)}'}）';
          return null;
      }

      // 成功判定：code=803，或任一 cookie 通道出现 MUSIC_U（响应体 + Set-Cookie 都收）
      final cookies = <String, String>{};
      final rawCookie = data['cookie'] ?? data['token'];
      if (rawCookie is String && rawCookie.trim().isNotEmpty) {
        cookies.addAll(_parseCookies(rawCookie));
      }
      _collectSetCookies(resp.headers, cookies);
      final musicU = cookies['MUSIC_U'] ?? cookies['MUSIC_A'] ?? '';
      _log('803 登录成功：cookie=[${cookies.keys.join(',')}] '
          'MUSIC_U=${_mask(musicU)}');
      if (musicU.isEmpty) {
        _lastError = '网易云登录成功但响应缺少 MUSIC_U 登录凭证（接口可能已变更）';
        return null;
      }
      final profile = data['profile'];
      var nickname = '';
      if (profile is Map) nickname = '${profile['nickname'] ?? ''}'.trim();
      if (nickname.isEmpty) nickname = '${data['nickname'] ?? ''}'.trim();
      if (nickname.isEmpty) nickname = '网易云用户';
      _cookies = Map<String, String>.of(cookies);
      _qrHint = null;
      _lastError = null;
      return AccountSession(
        platform: platform,
        cookies: _cookies,
        nickname: nickname,
      );
    } catch (e) {
      _qrHint = null;
      _lastError = _describeError(e, '网易云扫码轮询失败');
      _log('轮询异常：$_lastError');
      return null;
    }
  }

  /// 响应头 Set-Cookie 里的 cookie 名称列表（仅用于日志）
  static String _cookieNames(Headers headers) => (headers['set-cookie'] ??
          const <String>[])
      .map((e) => e.split(';').first.split('=').first.trim())
      .join(',');

  /// 解析 cookie 字符串（兼容 `a=b; c=d`、`a=b;;;c=d`，值里允许含 `=`）
  Map<String, String> _parseCookies(String raw) {
    final map = <String, String>{};
    for (final part in raw.split(RegExp(r';+'))) {
      final seg = part.trim();
      if (seg.isEmpty) continue;
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      map[seg.substring(0, eq).trim()] = seg.substring(eq + 1).trim();
    }
    return map;
  }

  @override
  void restoreSession(AccountSession? session) {
    _cookies = Map<String, String>.of(session?.cookies ?? const {});
  }

  /// 会话 cookie 拼成请求头值（MUSIC_U/__csrf 等；只发 music.163.com 官方域）
  String _cookieStr() =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// weapi 加密请求（原始 Response 版本；登录等需要读 Set-Cookie 的场景使用）
  Future<Response<dynamic>> _weapiResponse(
      String path, Map<String, dynamic> data) async {
    final enc = NeteaseCrypto.weapi(data);
    return JXHttp.dio.post(
      '$_baseWeb$path',
      data: {'params': enc['params'], 'encSecKey': enc['encSecKey']},
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        headers: {
          if (_cookies.isNotEmpty) 'Cookie': _cookieStr(),
          'Referer': 'https://music.163.com/',
        },
      ),
    );
  }

  /// weapi 加密请求
  Future<Map<String, dynamic>> _weapi(String path, Map<String, dynamic> data) async {
    final resp = await _weapiResponse(path, data);
    return resp.data as Map<String, dynamic>;
  }

  // ---- 手机号/邮箱 + 密码登录（eapi /w/login[/cellphone]，weapi 兜底）----
  // 对照维护中的 NeteaseCloudMusicApi-enhanced（main 分支，2026）：
  //   · 手机号：eapi /api/w/login/cellphone
  //     {type:'1', https, phone, countrycode:'86', password(md5), remember, secureCaptcha}
  //   · 邮箱：eapi /api/w/login {type:'0', https, username, password(md5), rememberLogin}
  //   · weapi 旧通道兜底（eapi 域不可达等场景）：
  //     /login/cellphone {phone, countrycode, md5_password, rememberLogin} 或 /login
  // 风控：code=-460 为 IP 级“网络环境风险”拦截，weapi/eapi/linuxapi 换通道
  // 均无法绕过（本机实测），只能切换网络或改用扫码登录。
  // 成功判定与扫码一致：任一 cookie 通道出现 MUSIC_U。

  /// eapi 通道基础地址（PC 客户端接口域）
  static const String _baseEapi = 'https://interfacepc.music.163.com/eapi';

  /// eapi 稳定设备 ID（实例级复用，模拟真实客户端）
  String? _eapiDeviceId;

  /// eapi 加密请求（e_r=false，响应为明文 JSON）
  Future<Response<dynamic>> _eapiResponse(
      String uri, Map<String, dynamic> data) async {
    final deviceId = _eapiDeviceId ??= List<int>.generate(
            32, (_) => math.Random.secure().nextInt(16))
        .map((b) => b.toRadixString(16))
        .join();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final requestId =
        '${nowMs}_${(math.Random.secure().nextInt(1000)).toString().padLeft(4, '0')}';
    final header = <String, String>{
      'osver': 'Microsoft-Windows-10-Professional-build-19045-64bit',
      'deviceId': deviceId,
      'os': 'pc',
      'appver': '3.1.17.204416',
      'versioncode': '140',
      'mobilename': '',
      'buildver': '${nowMs ~/ 1000}',
      'resolution': '1920x1080',
      '__csrf': _cookies['__csrf'] ?? '',
      'channel': 'netease',
      'requestId': requestId,
      if (_cookies.containsKey('MUSIC_U')) 'MUSIC_U': _cookies['MUSIC_U']!,
    };
    final body = <String, dynamic>{...data, 'e_r': false, 'header': header};
    final cookieHeader = header.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('; ');
    return JXHttp.dio.post(
      // uri='/api/w/login/cellphone' → '/eapi/w/login/cellphone'（保留斜杠）
      '$_baseEapi${uri.substring(4)}',
      data: 'params=${NeteaseCrypto.eapi(uri, body)}',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (s) => s != null && s < 500,
        receiveTimeout: const Duration(seconds: 20),
        headers: {
          'Cookie': cookieHeader,
          'Referer': '', // 阻断全局拦截器补 music.163.com Referer
          'User-Agent': 'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)',
        },
      ),
    );
  }

  /// weapi 验证码下发通道（对照上游 captcha_sent.js：
  /// /api/sms/captcha/sent {ctcode, secrete, cellphone}，weapi 去 /api 前缀）
  @override
  Future<bool> sendSmsCode(String mobile) async {
    _lastError = null;
    final phone = mobile.trim();
    if (phone.isEmpty) {
      _lastError = '请输入手机号';
      return false;
    }
    _log('发送验证码：手机号 ${_mask(phone)}');
    try {
      final resp =
          await _weapiResponse('/sms/captcha/sent', <String, dynamic>{
        'ctcode': '86',
        'secrete': 'music_middleuser_pclogin',
        'cellphone': phone,
        // 上游 weapi 请求统一追加 csrf_token（util/request.js）
        'csrf_token': _cookies['__csrf'] ?? '',
      });
      // 留存 NMTID 等匿名会话 cookie：验证码校验可能与发码会话绑定，
      // 登录请求需原样带回（上游 cookie jar 同款行为）
      _collectSetCookies(resp.headers, _cookies);
      final body = resp.data is Map ? resp.data as Map : null;
      if (body == null) {
        _lastError = '验证码发送失败：服务端无响应';
        _log(_lastError!);
        return false;
      }
      final code = _codeOf(body['code']);
      if (code == 200) {
        _log('验证码已下发');
        return true;
      }
      if (code == -460) {
        _lastError = '网易云风控拦截（-460）：当前网络环境被判定存在风险，'
            '请切换网络（如切换流量/WiFi）后重试';
      } else {
        final message = '${body['message'] ?? body['msg'] ?? ''}'.trim();
        _lastError = '验证码发送失败（code=$code'
            '${message.isEmpty ? '' : '：${_short(message, 120)}'}）';
      }
      _log(_lastError!);
      return false;
    } catch (e) {
      _lastError = '验证码发送失败：${_describeError(e, '网络异常')}';
      _log(_lastError!);
      return false;
    }
  }

  /// 验证码登录：weapi 主通道 /w/login/cellphone（与上游 login_cellphone.js
  /// 完全同通道，验证码由 weapi /sms/captcha/sent 下发，跨通道校验会报
  /// 「ursToken或验证码不存在」）；eapi 仅作通道级兜底
  @override
  Future<AccountSession?> loginBySmsCode(String mobile, String code) async {
    _lastError = null;
    final phone = mobile.trim();
    final captcha = code.trim();
    if (phone.isEmpty || captcha.isEmpty) {
      _lastError = '请输入手机号和验证码';
      return null;
    }
    _log('验证码登录：手机号 ${_mask(phone)}');
    final loginData = <String, dynamic>{
      'type': '1',
      'https': 'true',
      'phone': phone,
      'countrycode': '86',
      'captcha': captcha,
      'remember': 'true',
      'secureCaptcha': '',
    };
    // weapi 主通道（music.163.com/weapi/w/login/cellphone）
    Response<dynamic>? resp;
    try {
      resp = await _weapiResponse('/w/login/cellphone', <String, dynamic>{
        ...loginData,
        // 上游 weapi 请求统一追加 csrf_token（util/request.js）
        'csrf_token': _cookies['__csrf'] ?? '',
      });
      final body = resp.data is Map ? resp.data as Map : null;
      final respCode = _codeOf(body?['code']);
      // 通道级失败（无响应体/-460 风控/404 路径）才降级 eapi；
      // 业务错误码（如 503 验证码不存在）为权威结论
      if (body == null || respCode == -460 || respCode == 404) resp = null;
    } catch (e) {
      resp = null;
      _log('weapi 通道异常，改用 eapi：${_describeError(e, '')}');
    }
    // eapi 兜底（interfacepc /w/login/cellphone）
    if (resp == null) {
      try {
        final fallback = await _eapiResponse('/api/w/login/cellphone', loginData);
        if (fallback.data is Map) resp = fallback;
      } catch (_) {
        // eapi 也失败则保持 resp=null，走无响应提示
      }
    }
    return _sessionFromLoginResponse(resp);
  }

  @override
  Future<AccountSession?> loginByPassword(
      String username, String password) async {
    _lastError = null;
    final account = username.trim();
    if (account.isEmpty || password.isEmpty) {
      _lastError = '请输入手机号和密码';
      return null;
    }
    final isEmail = account.contains('@');
    final md5Pwd = _md5Hex(password);
    _log('密码登录：${isEmail ? '邮箱' : '手机号'} ${_mask(account)}');
    // eapi 主通道
    Response<dynamic>? resp;
    try {
      resp = await _eapiResponse(
        isEmail ? '/api/w/login' : '/api/w/login/cellphone',
        <String, dynamic>{
          'type': isEmail ? '0' : '1',
          'https': 'true',
          if (isEmail)
            'username': account
          else ...{
            'phone': account,
            'countrycode': '86',
          },
          'password': md5Pwd,
          if (isEmail) 'rememberLogin': 'true' else 'remember': 'true',
          if (!isEmail) 'secureCaptcha': '',
        },
      );
      final body = resp.data is Map ? resp.data as Map : null;
      final code = _codeOf(body?['code']);
      // 服务端已给出明确结论（成功/密码错等）时直接采用；
      // -460 风控 / 404（路径或网关问题）不可信，清空走 weapi 兜底
      if (body == null || code == -460 || code == 404) resp = null;
    } catch (e) {
      resp = null;
      _log('eapi 通道异常，改用 weapi：${_describeError(e, '')}');
    }
    // weapi 兜底（eapi 无响应 / -460 风控时再试一次，取更可用的结果）
    if (resp == null) {
      try {
        final fallback = await _weapiResponse(
          isEmail ? '/login' : '/login/cellphone',
          <String, dynamic>{
            if (isEmail)
              'username': account
            else ...{
              'phone': account,
              'countrycode': '86',
            },
            'md5_password': md5Pwd,
            'rememberLogin': 'true',
          },
        );
        // weapi 有明确响应体（即使业务错误码）比 eapi 的 -460 更可用
        if (fallback.data is Map) resp = fallback;
      } catch (_) {
        // weapi 也失败则保持 resp=null，走无响应提示
      }
    }
    return _sessionFromLoginResponse(resp);
  }

  /// 登录响应收尾：风控/错误码 → _lastError；成功 → 提取 MUSIC_U 与资料
  AccountSession? _sessionFromLoginResponse(Response<dynamic>? resp) {
    final body = resp?.data is Map ? resp?.data as Map : null;
    if (resp == null || body == null) {
      _lastError = '网易云登录失败：服务端无响应';
      _log(_lastError!);
      return null;
    }
    final code = _codeOf(body['code']);
    if (code == -460) {
      _lastError = '网易云风控拦截（-460）：当前网络环境被判定存在风险，'
          '请切换网络（如切换流量/WiFi）后重试，或改用扫码登录';
      _log(_lastError!);
      return null;
    }
    if (code != 200) {
      final message = '${body['message'] ?? body['msg'] ?? ''}'.trim();
      _lastError = '网易云登录失败（code=$code'
          '${message.isEmpty ? '' : '：${_short(message, 120)}'}）';
      _log(_lastError!);
      return null;
    }
    final cookies = <String, String>{};
    final rawCookie = body['cookie'];
    if (rawCookie is String && rawCookie.trim().isNotEmpty) {
      cookies.addAll(_parseCookies(rawCookie));
    }
    _collectSetCookies(resp.headers, cookies);
    final musicU = cookies['MUSIC_U'] ?? cookies['MUSIC_A'] ?? '';
    if (musicU.isEmpty) {
      _lastError = '网易云登录成功但未取得 MUSIC_U 登录凭证';
      _log(_lastError!);
      return null;
    }
    final profile = body['profile'];
    var nickname =
        profile is Map ? '${profile['nickname'] ?? ''}'.trim() : '';
    if (nickname.isEmpty) nickname = '网易云用户';
    final avatar = profile is Map ? '${profile['avatarUrl'] ?? ''}' : '';
    _cookies = Map<String, String>.of(cookies);
    _lastError = null;
    _log('登录成功：cookie=[${cookies.keys.join(',')}] '
        'MUSIC_U=${_mask(musicU)} nickname=$nickname');
    return AccountSession(
      platform: platform,
      cookies: _cookies,
      nickname: nickname,
      avatarUrl: avatar.isEmpty ? null : jxNormalizeImageUrl(avatar),
    );
  }
}
