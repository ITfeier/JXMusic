import 'dart:convert';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import '../../models/song.dart';
import '../../models/playlist.dart';
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

  /// 合并响应头里的 Set-Cookie（803 成功时 MUSIC_U 在响应头，不在响应体）
  void _collectSetCookies(Headers headers, Map<String, String> into) {
    final list = headers['set-cookie'];
    if (list == null) return;
    for (final item in list) {
      final seg = item.split(';').first.trim();
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      into[seg.substring(0, eq).trim()] = seg.substring(eq + 1).trim();
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
    for (final br in const [128000, 320000]) {
      try {
        final resp = await JXHttp.dio.get(
          '$_base/song/enhance/player/url',
          queryParameters: {'ids': '[$sid]', 'br': br},
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
      final resp = await JXHttp.dio.get('$_base/song/lyric', queryParameters: {
        'id': song.id,
        'lv': -1,
        'kv': -1,
        'tv': -1,
      });
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

  // ---- 扫码登录（公开二维码登录流程）----
  //
  // 2026-11 实测（本机直连）：`/api/login/qrcode/unikey` 与
  // `/api/login/qrcode/client/login` 仍可用，未扫码时返回
  // `{"code":801,"message":"等待扫码"}`。旧实现的问题：
  //   1) 轮询用 `resp.data['code'] as int?` 强转，code 为字符串时直接抛 TypeError，
  //      异常被设置页 `_poll` 的 catch 静默吞掉 -> 永远停在等待态；
  //   2) 只读响应体 `cookie` 字段，而 2026 现行接口 803 的 MUSIC_U 在**响应头
  //      Set-Cookie** 里（见 docs/接口清单.md 记录），导致"登录成功但没有凭证"；
  //   3) 无 lastError、无日志，失败不可见。
  @override
  Future<({String qrUrl, String key})> createQrLogin() async {
    // 旧接口 /login/qr/key + /login/qr/create 已下线（302→404），
    // 改用公开接口 api/login/qrcode/unikey 获取 unikey，二维码内容为官方登录页。
    _lastError = null;
    try {
      final resp = await JXHttp.dio.post('$_musicBase/api/login/qrcode/unikey',
          data: {'type': 1},
          options: Options(
            contentType: 'application/x-www-form-urlencoded',
            receiveTimeout: const Duration(seconds: 10),
            validateStatus: (s) => s != null && s < 500,
          ));
      final data = resp.data is Map ? resp.data as Map : const {};
      final key = '${data['unikey'] ?? ''}'.trim();
      _log('取码 HTTP=${resp.statusCode} code=${data['code']} unikey=${_mask(key)}');
      if (key.isEmpty || key == 'null') {
        _lastError =
            '网易云取码失败（HTTP ${resp.statusCode}，响应缺少 unikey，接口可能已变更）';
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
    try {
      final resp = await JXHttp.dio.post(
          '$_musicBase/api/login/qrcode/client/login',
          data: {'key': key, 'type': 1},
          options: Options(
            contentType: 'application/x-www-form-urlencoded',
            receiveTimeout: const Duration(seconds: 10),
            validateStatus: (s) => s != null && s < 500,
          ));
      final data = resp.data is Map ? resp.data as Map : const {};
      final code = _codeOf(data['code']);
      final message = '${data['message'] ?? data['msg'] ?? ''}'.trim();
      _log('轮询 HTTP=${resp.statusCode} code=$code'
          '${message.isEmpty ? '' : ' message=$message'}');
      switch (code) {
        case 801: // 等待扫码
          _lastError = null;
          return null;
        case 802: // 已扫码，等待手机端确认
          _lastError = '已扫码，请在手机上确认登录';
          return null;
        case 800: // 二维码过期
          _lastError = '二维码已过期，请关闭后重新获取';
          return null;
        case 803: // 登录成功
          break;
        default:
          _lastError = '网易云扫码登录失败（HTTP ${resp.statusCode}，code=$code'
              '${message.isEmpty ? '' : '，${_short(message, 120)}'}）';
          return null;
      }

      // 803：MUSIC_U 可能在响应体 cookie 字段（旧接口），也可能只在响应头
      // Set-Cookie（2026 现行接口），两者都收集。
      final cookies = <String, String>{};
      final rawCookie = data['cookie'] ?? data['token'];
      if (rawCookie is String && rawCookie.trim().isNotEmpty) {
        cookies.addAll(_parseCookies(rawCookie));
      }
      _collectSetCookies(resp.headers, cookies);
      final musicU = cookies['MUSIC_U'] ?? cookies['MUSIC_A'] ?? '';
      _log('803 登录成功：cookie=[${cookies.keys.join(',')}] MUSIC_U=${_mask(musicU)}');
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
      _lastError = null;
      return AccountSession(
        platform: platform,
        cookies: _cookies,
        nickname: nickname,
      );
    } catch (e) {
      _lastError = _describeError(e, '网易云扫码轮询失败');
      _log('轮询异常：$_lastError');
      return null;
    }
  }

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
