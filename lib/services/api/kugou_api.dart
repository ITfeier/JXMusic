import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../models/song.dart';
import '../../models/playlist.dart';
import '../../models/artist.dart';
import '../../models/album.dart';
import '../../models/lyric_hit.dart';
import 'music_api.dart';
import 'http.dart';
import 'kugou_login_crypto.dart';

/// 酷狗音乐接口（公开接口逆向，基础能力无需登录）
class KuGouApi implements MusicPlatformApi {
  @override
  int get platform => 2;

  static const String _search =
      'https://songsearch.kugou.com/song_search_v2';
  static const String _playData = 'https://wwwapi.kugou.com/yy/index.php';
  static const String _songInfo = 'https://m.kugou.com/app/i/getSongInfo.php';

  // ---- 酷狗官方扫码登录（login-user.kugou.com 协议，Android 客户端型二维码）----
  // 2026-11-19 对照 MakcRe/KuGouMusicApi main 定案：
  // · 取码 /v2/qrcode 用 appid=1001（Android 客户端型二维码；1014 是 H5 网页型），
  //   qrcode_txt 内嵌 appid=1005（酷狗音乐 Android 客户端），已实测返回同结构
  //   data.qrcode + qrcode_img；
  // · 轮询 /v2/get_userinfo_qrcode 用 appid=1005（config.json）、clientver=20489、
  //   srcappid=2919 → status=4 返回的 token 是 **Android 型（1005）token**；
  // · 旧 H5（1014）token 被 cloudlist get_all_list 以 error_code=20017 拒绝
  //   （真机实测，账号歌单页「登录已过期」的根因；v5/login_by_token 等 Android 域
  //   接口同样返回 20018/20006/20017）；
  // · status=4 的 token+userid 就是完整登录态：写入 Cookie 后免费歌曲
  //   getSongInfo.php 实测返回 status=1 + 可播 sharefs 直链；
  // · 设备 mid（十进制）首次生成后以 kg_mid 存进会话 cookie，登录与账号歌单
  //   请求共用，保持设备身份一致。
  static const String _loginBase = 'https://login-user.kugou.com/';
  static const String _qrcodeH5 =
      'https://h5.kugou.com/apps/loginQRCode/html/index.html';
  static const String _kgSalt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
  static const String _dfid = '-';
  static const String _loginReferer =
      'https://login-user.kugou.com/login/?appid=1014';
  /// 探针开关：`dart run -DJX_PROBE=true` 时打印账号歌单原始响应，
  /// 正常构建（含 release）编译期剔除。
  static const bool _probe = bool.fromEnvironment('JX_PROBE');
  final Map<String, String> _cookies = {};
  String? _qrKey;
  String? _kgMid;

  /// 最近一次扫码操作失败原因（成功/等待时为 null，供设置页展示准确提示）
  String? _lastError;

  /// 最近一次扫码轮询是否为终态（status=0 二维码已过期，QA D-05）：
  /// 终态再轮询无意义，设置页据此提前停止轮询（不必空转到 2 分钟）。
  bool _qrTerminal = false;

  @override
  bool get qrTerminal => _qrTerminal;

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
      final root = resp.data is Map ? resp.data as Map : const {};
      final url = root['url'] as String?;
      // 真机修复（+43）：统一升级 https，防设备端 libmpv 打开明文直链失败。
      if (url != null && url.isNotEmpty) return jxUpgradeHttps(url);
      // 付费/VIP 歌（实测 status=0 + error="需要付费"）：写明具体原因（QA #3），
      // 死链提示展示「该歌曲可能需要会员或付费」而非笼统「链接已失效」。
      final status = (root['status'] as num?)?.toInt();
      final err = '${root['error'] ?? ''}'.trim();
      if (status == 0 && err.isNotEmpty) {
        _lastError = '酷狗：$err（该歌曲可能需要会员或付费）';
      }
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
      return jxUpgradeHttps(url);
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
    // mobiles.kugou.com 的歌单详情接口，返回 data.info 歌曲数组。
    // 分页契约与 QQ 对齐（QA #5）：page=1 聚合整单（歌单详情页按全量展示/整单入队，
    // 不能只有前 100 首），page>1 本地切片兑现分页。服务端单页上限约 100 条，
    // 超过 100 首的歌单在 page=1 内部按 100 条/页翻页聚合（上限 10 页）。
    try {
      const perPage = 100;
      // gcid 形态的歌单 id（m.kugou.com/songlist/gcid_XXX/ 分享链接里的全球集合
      // ID，字母数字混合）不能直接查 special/song（实测返回「参数不合法」）：
      // 先经 m.kugou.com 歌单页映射成数字 specialid（页面内嵌
      // `"specialid":2509422`），2026-11 探针实测可用。
      var specialId = playlist.id;
      if (!RegExp(r'^\d+$').hasMatch(specialId)) {
        final pageResp = await JXHttp.dio.get(
          'https://m.kugou.com/songlist/gcid_$specialId/',
          // 桌面 UA 会被 301 到 www.kugou.com，页面不内嵌 specialid 映射；
          // 必须用移动浏览器 UA 才能拿到 m. 站映射页（2026-11 实测）。
          options: Options(
            responseType: ResponseType.plain,
            headers: {'User-Agent': _mobileUa},
          ),
        );
        final html = pageResp.data is String ? pageResp.data as String : '';
        specialId =
            RegExp(r'"specialid":(\d+)').firstMatch(html)?.group(1) ?? '';
        if (specialId.isEmpty) return const [];
      }
      final all = <Map<String, dynamic>>[];
      String? firstKey;
      for (var p = 1; p <= 10; p++) {
        final resp = await JXHttp.dio.get(
          'https://mobiles.kugou.com/api/v3/special/song',
          queryParameters: {
            'specialid': specialId,
            'page': p,
            'pagesize': perPage,
            'plat': 0,
            'version': 8000,
          },
        );
        final list = (resp.data['data']?['info'] as List?) ?? const [];
        if (list.isEmpty) break;
        final maps = list.map((s) => s as Map<String, dynamic>).toList();
        // 接口忽略 page 参数时会一直返回第一页：首元素 hash 与上页相同即停，
        // 避免同一页被堆叠（最多 10 页重复数据）。
        final key = '${maps.first['hash'] ?? ''}';
        if (firstKey != null && key == firstKey) break;
        firstKey ??= key;
        all.addAll(maps);
        if (maps.length < perPage) break;
      }
      var sliced = all;
      if (page > 1) {
        sliced = all.skip((page - 1) * size).take(size).toList();
      }
      return sliced.map<Song>((m) {
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

  /// 歌单元数据：仅 gcid 形态支持——m.kugou.com 歌单页内嵌 `listinfo`
  /// JSON（name/pic/count/list_create_username/specialid，2026-11 探针
  /// 实测）。数字 specialid 无公开元数据接口（plist/info 已失效），返回
  /// null 走手填名称兜底。
  @override
  Future<Playlist?> playlistInfo(Playlist playlist) async {
    if (RegExp(r'^\d+$').hasMatch(playlist.id)) return null;
    try {
      final pageResp = await JXHttp.dio.get(
        'https://m.kugou.com/songlist/gcid_${playlist.id}/',
        options: Options(
          responseType: ResponseType.plain,
          headers: {'User-Agent': _mobileUa},
        ),
      );
      final html = pageResp.data is String ? pageResp.data as String : '';
      // listinfo 紧邻 "songs":[ 之前；内部无该锚点序列，lazy 匹配安全
      final raw = RegExp(r'"listinfo":(\{.+?\}),"songs":\[')
              .firstMatch(html)
              ?.group(1) ??
          '';
      if (raw.isEmpty) return null;
      final info = jsonDecode(raw);
      if (info is! Map) return null;
      final title = _clean(info['name'] as String?);
      final cover = _image(info['pic'] as String?);
      if (title.isEmpty && cover.isEmpty) return null;
      return Playlist(
        id: playlist.id,
        platform: platform,
        title: title,
        coverUrl: cover,
        creator: _clean(info['list_create_username'] as String?),
        songCount: (info['count'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
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

  // ---- 分类搜索与详情（gateway android 签名；2026-11 探针实测）----

  /// 分类搜索共用的 mid（40 位数字；每次会话固定，避免随机变动触发风控）
  String? _searchMid;

  String _randomSearchMid() => String.fromCharCodes(
      List<int>.generate(40, (_) => 48 + Random().nextInt(10)));

  static const String _gatewayUa =
      'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

  /// 移动浏览器 UA：请求 m.kugou.com 页面必须带（桌面 UA 被 301 到
  /// www.kugou.com，页面不内嵌歌单数据，2026-11 实测）。
  static const String _mobileUa =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// gateway android 签名 GET（分类搜索 /v1/search/*、歌手歌曲等）
  Future<Map?> _gatewaySignedGet(String path, Map<String, String> params,
      {Map<String, String> headers = const {}}) async {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final mid = _searchMid ??= _randomSearchMid();
    final p = Map<String, String>.of(params);
    p['dfid'] = _dfid;
    p['mid'] = mid;
    p['uuid'] = '-';
    p['appid'] = KugouLoginCrypto.appid;
    p['clientver'] = KugouLoginCrypto.clientver;
    p['clienttime'] = '$clienttime';
    p['signature'] = KugouLoginCrypto.androidSignature(p, '');
    final resp = await JXHttp.dio.get(
      'https://gateway.kugou.com$path',
      queryParameters: p,
      options: Options(
        validateStatus: (s) => s != null && s < 500,
        headers: {'User-Agent': _gatewayUa, ...headers},
      ),
    );
    return resp.data is Map ? resp.data as Map : null;
  }

  /// gateway android 签名 POST（专辑歌曲 /v1/album_audio/lite、账号歌单
  /// /v7/get_all_list 等）。[mid] 缺省时用匿名搜索 mid；登录态相关请求
  /// 必须传会话持久化的 kg_mid（与登录时一致，否则网关按异常设备拒绝）。
  Future<Map?> _gatewaySignedPost(
      String path, Map<String, dynamic> body, String router,
      {Map<String, String> headers = const {},
      Map<String, String> query = const {},
      String? mid}) async {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final useMid = mid ?? (_searchMid ??= _randomSearchMid());
    final bodyStr = jsonEncode(body);
    final params = <String, String>{
      ...query,
      'dfid': _dfid,
      'mid': useMid,
      'uuid': '-',
      'appid': KugouLoginCrypto.appid,
      'clientver': KugouLoginCrypto.clientver,
      'clienttime': '$clienttime',
    };
    params['signature'] = KugouLoginCrypto.androidSignature(params, bodyStr);
    final resp = await JXHttp.dio.post(
      'https://gateway.kugou.com$path',
      queryParameters: params,
      data: bodyStr,
      options: Options(
        contentType: 'application/json',
        validateStatus: (s) => s != null && s < 500,
        headers: {'x-router': router, 'User-Agent': _gatewayUa, ...headers},
      ),
    );
    return resp.data is Map ? resp.data as Map : null;
  }

  @override
  Future<List<Playlist>> searchPlaylists(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final root = await _gatewaySignedGet('/v1/search/special', {
        'keyword': keyword, 'page': '$page', 'pagesize': '$size',
        'platform': 'AndroidFilter', 'iscorrection': '1',
        'nocollect': '0',
      }, headers: {'x-router': 'complexsearch.kugou.com'});
      final list = (root?['data']?['lists'] as List?) ?? const [];
      return list.map<Playlist>((raw) {
        final m = raw as Map<String, dynamic>;
        return Playlist(
          id: '${m['specialid'] ?? ''}',
          platform: platform,
          title: _clean(m['specialname'] as String?),
          coverUrl: _image(m['img'] as String?),
          creator: _clean(m['nickname'] as String?),
          songCount: (m['song_count'] as num?)?.toInt() ?? 0,
        );
      }).where((p) => p.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Artist>> searchArtists(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final root = await _gatewaySignedGet('/v1/search/author', {
        'keyword': keyword, 'page': '$page', 'pagesize': '$size',
        'platform': 'AndroidFilter', 'iscorrection': '1',
      }, headers: {'x-router': 'complexsearch.kugou.com'});
      final list = (root?['data']?['lists'] as List?) ?? const [];
      return list.map<Artist>((raw) {
        final m = raw as Map<String, dynamic>;
        return Artist(
          id: '${m['AuthorId'] ?? m['author_id'] ?? ''}',
          platform: platform,
          name: _clean(m['AuthorName'] as String? ?? m['author_name'] as String?),
          avatarUrl: _image(m['Avatar'] as String? ?? m['avatar'] as String?),
          albumCount: (m['AlbumCount'] as num?)?.toInt() ?? 0,
          songCount: (m['AudioCount'] as num?)?.toInt() ?? 0,
        );
      }).where((a) => a.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Album>> searchAlbums(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final root = await _gatewaySignedGet('/v1/search/album', {
        'keyword': keyword, 'page': '$page', 'pagesize': '$size',
        'platform': 'AndroidFilter', 'iscorrection': '1',
        'category': '1', 'sorttype': '0', 'searchsong': '0',
      }, headers: {'x-router': 'complexsearch.kugou.com'});
      final list = (root?['data']?['lists'] as List?) ?? const [];
      return list.map<Album>((raw) {
        final m = raw as Map<String, dynamic>;
        final publish = '${m['publish_time'] ?? ''}';
        return Album(
          id: '${m['albumid'] ?? m['AlbumID'] ?? ''}',
          platform: platform,
          name: _clean(m['albumname'] as String? ?? m['AlbumName'] as String?),
          coverUrl: _image(m['img'] as String?),
          artist: _clean(m['singer'] as String? ?? m['SingerName'] as String?),
          songCount: (m['songcount'] as num?)?.toInt() ??
              (m['SongCount'] as num?)?.toInt() ??
              0,
          publishTime: publish.length > 10 ? publish.substring(0, 10) : publish,
        );
      }).where((a) => a.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<LyricHit>> searchLyrics(String keyword,
      {int page = 1, int size = 30}) async {
    try {
      final root = await _gatewaySignedGet('/v1/search/lyric', {
        'keyword': keyword, 'page': '$page', 'pagesize': '$size',
        'platform': 'AndroidFilter', 'iscorrection': '1',
      }, headers: {'x-router': 'complexsearch.kugou.com'});
      final list = (root?['data']?['lists'] as List?) ?? const [];
      return list.map<LyricHit>((raw) {
        final m = raw as Map<String, dynamic>;
        return LyricHit(
          song: Song(
            id: '${m['FileHash'] ?? m['hash'] ?? ''}',
            platform: platform,
            title: _clean(m['SongName'] as String?),
            artist: _clean(m['SingerName'] as String?),
            album: _clean(m['AlbumName'] as String?),
            coverUrl: _image(m['Image'] as String?),
            duration: (m['TimeLength'] as num?)?.toInt() ?? 0,
            vip: ((m['Privilege'] as num?)?.toInt() ?? 0) >= 10,
          ),
          snippet: _clean(m['Lyric'] as String?),
        );
      }).where((h) => h.song.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  // ---- 登录账号歌单（POST /v7/get_all_list，x-router: cloudlist.service.kugou.com，
  //      对照 MakcRe/KuGouMusicApi module/user_playlist.js）----

  @override
  Future<List<Playlist>> userPlaylists(
      {int page = 1, int size = 30}) async {
    final userid = _cookies['userid'] ?? '';
    final token = _cookies['token'] ?? '';
    if (userid.isEmpty || token.isEmpty) return const [];
    try {
      final root = await _gatewaySignedPost(
        '/v7/get_all_list',
        {
          'userid': userid,
          'token': token,
          'total_ver': 979,
          'type': 2,
          'page': page,
          'pagesize': size,
        },
        'cloudlist.service.kugou.com',
        query: {'plat': '1', 'userid': userid, 'token': token},
        headers: {'Cookie': _cookieStr},
        // 设备 mid 与登录时保持一致（kg_mid 随会话持久化）：
        // 20017 的一部分诱因是网关按 mid/dfid 校验设备身份。
        mid: _cookies['kg_mid'],
      );
      if (_probe && root != null) {
        // ignore: avoid_print
        print('[probe] kugou get_all_list root: ${jsonEncode(root)}');
      }
      // 网关拒绝当前会话时只回业务错误码（探针实测失效 token：
      // {"status":0,"error_code":20017}），必须与「0 个歌单」区分开
      final errorCode = root == null ? null : root['error_code'];
      if (root == null || errorCode is int && errorCode != 0) {
        final code = errorCode is int ? errorCode : 0;
        throw SessionExpiredException(
          code == 0
              ? '网络错误或登录已过期，请重试'
              : code == 20017
                  ? '登录已过期，请重新登录'
                  : code == 20028
                      ? '触发安全验证，请重新登录'
                      : '登录状态异常（错误码 $code），请重新登录',
        );
      }
      final data = root['data'];
      final list = ((data is Map ? data['list'] : null) as List?) ??
          (root['list'] as List?) ??
          const [];
      return list.map<Playlist>((raw) {
        final m = raw is Map ? raw : const {};
        return Playlist(
          id: '${m['specialid'] ?? m['global_special_id'] ?? m['id'] ?? ''}',
          platform: platform,
          title: _clean(
              '${m['specialname'] ?? m['name'] ?? m['title'] ?? ''}'),
          coverUrl: _image(
              '${m['img'] ?? m['imgurl'] ?? m['cover'] ?? m['pic'] ?? ''}'),
          creator: _clean('${m['nickname'] ?? m['username'] ?? ''}'),
          songCount: (m['count'] as num?)?.toInt() ??
              (m['songnum'] as num?)?.toInt() ??
              (m['song_count'] as num?)?.toInt() ??
              0,
        );
      }).where((p) => p.id.isNotEmpty && p.title.isNotEmpty).toList();
    } on SessionExpiredException {
      rethrow;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Song>> artistSongs(Artist artist,
      {int page = 1, int size = 30}) async {
    if (artist.id.isEmpty) return const [];
    try {
      // 歌手热门歌曲：/openapi/kmr/v2/audio_group/author（探针实测，
      // sort=1 最热；返回 data.songs[]，可播 hash 在 audio_info.hash）
      final root = await _gatewaySignedGet(
        '/openapi/kmr/v2/audio_group/author',
        {
          'author_id': artist.id, 'area_code': 'all', 'sort': '1',
          'page': '$page', 'pagesize': '$size', 'replace_api_version': '1',
          'mvdata_need': '1', 'show_audio_honor': '1', 'show_audio_tag': '1',
          'replace_need': '1',
        },
        headers: {'kg-tid': '36'},
      );
      final list = (root?['data']?['songs'] as List?) ?? const [];
      return list.map<Song>((raw) {
        final m = raw as Map<String, dynamic>;
        final audioInfo = m['audio_info'] as Map? ?? const {};
        final albumInfo = m['album_info'] as Map? ?? const {};
        final privilege = m['privilege_download'] as Map? ?? const {};
        return Song(
          id: '${audioInfo['hash'] ?? ''}',
          platform: platform,
          title: _clean(m['audio_name'] as String?),
          artist: _clean(m['author_name'] as String?),
          album: _clean(albumInfo['album_name'] as String?),
          coverUrl: _image(albumInfo['cover'] as String?),
          duration: ((audioInfo['timelength'] as num?)?.toInt() ?? 0) ~/ 1000,
          vip: ((privilege['privilege_128'] as num?)?.toInt() ?? 0) >= 10,
        );
      }).where((s) => s.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Song>> albumSongs(Album album,
      {int page = 1, int size = 30}) async {
    if (album.id.isEmpty) return const [];
    try {
      // 专辑歌曲：POST /v1/album_audio/lite（探针实测；
      // 返回 data.songs[]：base.audio_name / audio_info.hash / album_info.cover）
      final root = await _gatewaySignedPost(
        '/v1/album_audio/lite',
        {
          'album_id': album.id,
          'is_buy': '',
          'page': page,
          'pagesize': size,
        },
        'openapi.kugou.com',
        headers: {'kg-tid': '255'},
      );
      final list = (root?['data']?['songs'] as List?) ?? const [];
      return list.map<Song>((raw) {
        final m = raw as Map<String, dynamic>;
        final audioInfo = m['audio_info'] as Map? ?? const {};
        final base = m['base'] as Map? ?? const {};
        final albumInfo = m['album_info'] as Map? ?? const {};
        final copyright = m['copyright'] as Map? ?? const {};
        final authors = (m['authors'] as List? ?? const [])
            .map((a) => (a as Map)['author_name'] as String? ?? '')
            .where((s) => s.isNotEmpty)
            .join('、');
        return Song(
          id: '${audioInfo['hash'] ?? ''}',
          platform: platform,
          title: _clean(base['audio_name'] as String?),
          artist: authors.isEmpty
              ? _clean(base['author_name'] as String?)
              : authors,
          album: _clean(albumInfo['album_name'] as String?),
          coverUrl: _image(albumInfo['cover'] as String?),
          duration: ((audioInfo['duration'] as num?)?.toInt() ??
                  (audioInfo['duration_128'] as num?)?.toInt() ??
                  0) ~/
              1000,
          vip: ((copyright['privilege'] as num?)?.toInt() ?? 0) >= 10,
        );
      }).where((s) => s.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  // ---- 扫码登录（login-user.kugou.com 协议，Android 客户端型二维码）----
  // 2026-11-19 对照 MakcRe/KuGouMusicApi main 定案：
  // · 取码 appid=1001、轮询 appid=1005/clientver=20489/srcappid=2919，
  //   status=4 返回的 token 是 Android 型（1005）token——cloudlist
  //   get_all_list 认它；旧 H5（1014）token 被拒 20017（真机实测，
  //   账号歌单「登录已过期」的根因）；
  // · token+userid 就是完整登录态：写入 Cookie 后免费歌 getSongInfo
  //   实测返回 status=1 + 可播 sharefs 直链；
  // · 设备 mid 以 kg_mid 随会话持久化，登录与账号歌单共用。
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
    // 设备 mid：复用会话里持久化的 kg_mid（跨登录稳定），否则新生成十进制 mid
    _kgMid = _cookies['kg_mid'] ?? _randomMidDecimal();
    _lastError = null;
    _qrTerminal = false;
    try {
      // GET https://login-user.kugou.com/v2/qrcode?<签名参数>
      // appid=1001（Android 客户端型二维码，对照 login_qr_key.js 默认分支）：
      // 扫码确认后拿到 Android 型（1005）token，账号歌单 cloudlist 才认
      // （H5 型 1014 二维码的 token 被 get_all_list 拒 20017，真机实测）。
      final params = <String, String>{
        'appid': '1001',
        'clientver': KugouLoginCrypto.clientver,
        'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
        'mid': _kgMid!,
        'uuid': '-',
        'dfid': _dfid,
        'type': '1',
        'plat': '4',
        'srcappid': '2919',
        'qrcode_txt': '$_qrcodeH5?appid=${KugouLoginCrypto.appid}&',
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
      final qrUrl = img.isNotEmpty
          ? img
          : '$_qrcodeH5?appid=${KugouLoginCrypto.appid}&qrcode=$key';
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
      // appid=1005（对照 login_qr_check.js）：与取码 appid=1001 配对，
      // 返回 Android 型（1005）token
      final mid = _kgMid ?? _randomMidDecimal();
      final params = <String, String>{
        'appid': KugouLoginCrypto.appid,
        'clientver': KugouLoginCrypto.clientver,
        'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
        'mid': mid,
        'uuid': '-',
        'dfid': _dfid,
        'plat': '4',
        'srcappid': '2919',
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
        _qrTerminal = false;
        return null;
      }
      if (status == 0) {
        _lastError = '二维码已过期，请关闭后重新获取';
        _qrTerminal = true; // QA D-05：过期终态，设置页提前停止轮询
        return null;
      }
      if (status != 4) {
        _lastError = null; // 其余按等待处理
        _qrTerminal = false;
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
      // 持久化设备 mid：账号歌单（get_all_list）等后续请求与登录共用设备身份
      _cookies['kg_mid'] = mid;
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

  // ---- 密码登录（/v9/login_by_pwd，KuGouMusicApi main 分支协议）----
  // 请求：POST https://gateway.kugou.com/v9/login_by_pwd
  //   · header x-router: login.user.kugou.com，android 签名（appid=1005）
  //   · body: plat/support_multi/clienttime_ms/t1/t2/t3/username/
  //     params(AES 加密 {pwd,code,clienttime_ms})/pk(RSA 加密 {clienttime_ms,key})
  // 响应：status=1 且 data.secu_params 用同一 tempKey 解密得到 token；
  //   token+userid 写入 Cookie 即登录态（与扫码 status=4 的结论一致）。

  /// 密码登录用的设备 mid（十进制字符串；官方由 md5(GUID) 转 BigInt 得到）
  String? _pwdMid;

  String _randomMidDecimal() {
    final digest = md5.convert(utf8.encode(_randomHex32())).toString();
    return BigInt.parse(digest, radix: 16).toString();
  }

  /// 合并响应头 Set-Cookie（忽略值为空的删除指令，避免清空行覆盖有效值）
  void _collectSetCookies(Headers headers) {
    final list = headers['set-cookie'];
    if (list == null) return;
    for (final item in list) {
      final seg = item.split(';').first.trim();
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final name = seg.substring(0, eq).trim();
      final value = seg.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      _cookies[name] = value;
    }
  }

  @override
  Future<AccountSession?> loginByPassword(
      String username, String password) async {
    _lastError = null;
    final account = username.trim();
    if (account.isEmpty || password.isEmpty) {
      _lastError = '请输入酷狗账号和密码';
      return null;
    }
    final mid = _pwdMid ??= _cookies['kg_mid'] ?? _randomMidDecimal();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final clienttime = nowMs ~/ 1000;
    final tempKey = KugouLoginCrypto.randomTempKey();
    // params：AES 加密 {pwd, code, clienttime_ms}
    final encParams = KugouLoginCrypto.aesEncryptHex(
      jsonEncode({'pwd': password, 'code': '', 'clienttime_ms': nowMs}),
      tempKey,
    );
    // pk：RSA 无填充加密 {clienttime_ms, key}，hex 大写
    final pk = KugouLoginCrypto.rsaEncryptHex(
      jsonEncode({'clienttime_ms': nowMs, 'key': tempKey}),
    ).toUpperCase();
    // body 的键序影响签名与 JSON 序列化，必须与 login.js 完全一致
    final body = jsonEncode(<String, dynamic>{
      'plat': 1,
      'support_multi': 1,
      'clienttime_ms': nowMs,
      't1': KugouLoginCrypto.t1,
      't2': KugouLoginCrypto.t2,
      't3': KugouLoginCrypto.t3,
      'username': account,
      'params': encParams,
      'pk': pk,
    });
    final params = <String, String>{
      'dfid': _dfid,
      'mid': mid,
      'uuid': '-',
      'appid': KugouLoginCrypto.appid,
      'clientver': KugouLoginCrypto.clientver,
      'clienttime': '$clienttime',
    };
    // android 签名：对查询参数 + body 字符串整体取 md5（签名本身不参与）
    final signature = KugouLoginCrypto.androidSignature(params, body);
    params['signature'] = signature;
    try {
      final resp = await JXHttp.dio.post(
        'https://gateway.kugou.com/v9/login_by_pwd',
        queryParameters: params,
        data: body,
        options: Options(
          contentType: 'application/json',
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'x-router': 'login.user.kugou.com',
            'dfid': _dfid,
            'clienttime': '$clienttime',
            'mid': mid,
            'kg-rc': '1',
            'kg-thash': '5d816a0',
            'kg-rec': '1',
            'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
            'User-Agent':
                'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
          },
        ),
      );
      _collectSetCookies(resp.headers);
      final root = resp.data is Map ? resp.data as Map : null;
      if (root == null) {
        _lastError = '酷狗登录返回空响应（接口可能已变更）';
        return null;
      }
      final status = (root['status'] as num?)?.toInt() ?? 0;
      if (status != 1) {
        final msg = '${root['msg'] ?? root['message'] ?? ''}'.trim();
        final errCode = '${root['error_code'] ?? ''}'.trim();
        // 常见错误码补充可操作提示（本机实测 20006/34175 + KuGouMusicApi #206 SSA）
        String hint = '';
        if (errCode == '20006') {
          hint = '。账号或密码错误：若账号未设置过密码（仅手机验证码注册），'
              '请先在酷狗 App 设置密码，或改用扫码登录';
        } else if (errCode == '34175') {
          hint = '。该手机号绑定了多个酷狗账号，请改用扫码登录';
        } else if (errCode == '20028' ||
            (resp.headers.value('ssa-code') ?? '').isNotEmpty) {
          hint = '。触发酷狗风控验证：多为短期内多次失败尝试累积所致，'
              '建议改用扫码登录，或等待数小时风控解除后再试';
        }
        _lastError = '酷狗登录失败：${msg.isNotEmpty ? msg : 'status=$status'}'
            '${errCode.isEmpty ? '' : '（error_code=$errCode）'}$hint';
        return null;
      }
      final data = root['data'] is Map ? root['data'] as Map : null;
      final secuParams = '${data?['secu_params'] ?? ''}';
      if (secuParams.isEmpty) {
        _lastError = '酷狗登录成功但未返回令牌（secu_params 缺失）';
        return null;
      }
      // secu_params 用同一 tempKey 解密：可能是 JSON（多键）或纯文本 token
      var plain = '';
      try {
        plain = KugouLoginCrypto.aesDecryptHex(secuParams, tempKey);
      } catch (_) {}
      Object? tokenInfo;
      try {
        tokenInfo = jsonDecode(plain);
      } catch (_) {
        tokenInfo = plain;
      }
      final tokenMap =
          tokenInfo is Map ? Map<String, dynamic>.from(tokenInfo) : null;
      final token =
          '${tokenMap?['token'] ?? (tokenInfo is String ? tokenInfo : '')}'
              .trim();
      if (token.isEmpty) {
        _lastError = '酷狗登录令牌解密失败（协议可能已变更）';
        return null;
      }
      _cookies['token'] = token;
      // 持久化设备 mid（kg_mid），账号歌单等请求与登录共用设备身份
      _cookies['kg_mid'] = mid;
      // 解密对象里的其余会话键值逐个写入 cookie（login.js 同款行为）
      tokenMap?.forEach((k, v) {
        final value = '$v';
        if (value.isEmpty || k == 'clienttime_ms') return;
        _cookies[k] = value;
      });
      final userid =
          '${data?['userid'] ?? tokenMap?['userid'] ?? ''}'.trim();
      if (userid.isNotEmpty) _cookies['userid'] = userid;
      final vipType = '${data?['vip_type'] ?? ''}'.trim();
      if (vipType.isNotEmpty) _cookies['vip_type'] = vipType;
      final vipToken = '${data?['vip_token'] ?? ''}'.trim();
      if (vipToken.isNotEmpty) _cookies['vip_token'] = vipToken;
      var nickname =
          '${tokenMap?['nickname'] ?? tokenMap?['nick_name'] ?? data?['nickname'] ?? ''}'
              .trim();
      if (nickname.isEmpty) nickname = '酷狗用户';
      final pic = tokenMap?['pic'] ?? tokenMap?['headimg'] ?? data?['pic'];
      _lastError = null;
      return AccountSession(
        platform: platform,
        cookies: Map.of(_cookies),
        nickname: nickname,
        avatarUrl:
            pic is String && pic.isNotEmpty ? jxNormalizeImageUrl(pic) : null,
      );
    } catch (e) {
      _lastError = _describeError(e, '酷狗密码登录失败');
      return null;
    }
  }

  // ---- 手机验证码登录（/v7/send_mobile_code + /v7/login_by_verifycode）----
  // 对照 KuGouMusicApi main 分支 module/captcha_sent.js、login_cellphone.js：
  //   · 发码：POST gateway.kugou.com/v7/send_mobile_code（x-router: login.user.kugou.com，
  //     该域 https 证书不匹配、上游用明文 http，故走 gateway 路由；本机实测 2026-11）
  //     body {businessid:5, mobile, plat:3}，android 签名
  //   · 验证码登录：POST loginserviceretry.kugou.com/v7/login_by_verifycode
  //     body 键序 plat/support_multi/t1(0)/t2(0)/clienttime_ms/mobile(脱敏)/
  //     key(signParamsKey)/pk(RSA)/params(AES {mobile,code})/t3
  //     headers support-calm:1，UA Android16-...-LOGIN-wifi
  //   · 成功：status=1 且 data.secu_params 用同一 tempKey 解密出 token（与密码登录一致）

  @override
  Future<bool> sendSmsCode(String mobile) async {
    _lastError = null;
    final phone = mobile.trim();
    if (phone.isEmpty) {
      _lastError = '请输入手机号';
      return false;
    }
    final mid = _pwdMid ??= _cookies['kg_mid'] ?? _randomMidDecimal();
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 键序与 captcha_sent.js 一致（影响 android 签名）
    final body = jsonEncode(<String, dynamic>{
      'businessid': 5,
      'mobile': phone,
      'plat': 3,
    });
    final params = <String, String>{
      'dfid': _dfid,
      'mid': mid,
      'uuid': '-',
      'appid': KugouLoginCrypto.appid,
      'clientver': KugouLoginCrypto.clientver,
      'clienttime': '$clienttime',
    };
    params['signature'] = KugouLoginCrypto.androidSignature(params, body);
    try {
      final resp = await JXHttp.dio.post(
        'https://gateway.kugou.com/v7/send_mobile_code',
        queryParameters: params,
        data: body,
        options: Options(
          contentType: 'application/json',
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'x-router': 'login.user.kugou.com',
            'User-Agent': 'Android16-1070-11440-130-0-LOGIN-wifi',
          },
        ),
      );
      final root = resp.data is Map ? resp.data as Map : null;
      if (root == null) {
        _lastError = '酷狗发送验证码返回空响应（接口可能已变更）';
        return false;
      }
      final status = (root['status'] as num?)?.toInt() ?? 0;
      if (status != 1) {
        // data 可能是错误文案（如 20010「手机格式不正确」），也可能为 null
        final msg =
            '${root['data'] is String ? root['data'] : (root['msg'] ?? root['message'] ?? '')}'
                .trim();
        final errCode = '${root['error_code'] ?? ''}'.trim();
        _lastError = '酷狗验证码发送失败：'
            '${msg.isNotEmpty ? msg : 'status=$status'}'
            '${errCode.isEmpty ? '' : '（error_code=$errCode）'}';
        return false;
      }
      return true;
    } catch (e) {
      _lastError = _describeError(e, '酷狗验证码发送失败');
      return false;
    }
  }

  @override
  Future<AccountSession?> loginBySmsCode(String mobile, String code) async {
    _lastError = null;
    final phone = mobile.trim();
    final smsCode = code.trim();
    if (phone.isEmpty || smsCode.isEmpty) {
      _lastError = '请输入手机号和验证码';
      return null;
    }
    final mid = _pwdMid ??= _cookies['kg_mid'] ?? _randomMidDecimal();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final clienttime = nowMs ~/ 1000;
    final tempKey = KugouLoginCrypto.randomTempKey();
    // params：AES 加密 {mobile, code}（完整手机号，明文只在加密体里）
    final encParams = KugouLoginCrypto.aesEncryptHex(
      jsonEncode(<String, dynamic>{'mobile': phone, 'code': smsCode}),
      tempKey,
    );
    // body 手机号脱敏（login_cellphone.js）：前 2 位 + 5 星 + 第 11 位
    final masked = phone.length == 11
        ? '${phone.substring(0, 2)}*****${phone.substring(10, 11)}'
        : phone;
    final pk = KugouLoginCrypto.rsaEncryptHex(
      jsonEncode(<String, dynamic>{'clienttime_ms': nowMs, 'key': tempKey}),
    ).toUpperCase();
    // 键序与 login_cellphone.js dataMap 插入顺序一致
    final body = jsonEncode(<String, dynamic>{
      'plat': 1,
      'support_multi': 1,
      't1': 0,
      't2': 0,
      'clienttime_ms': nowMs,
      'mobile': masked,
      'key': KugouLoginCrypto.signParamsKey('$nowMs'),
      'pk': pk,
      'params': encParams,
      't3': KugouLoginCrypto.t3,
    });
    final params = <String, String>{
      'dfid': _dfid,
      'mid': mid,
      'uuid': '-',
      'appid': KugouLoginCrypto.appid,
      'clientver': KugouLoginCrypto.clientver,
      'clienttime': '$clienttime',
    };
    params['signature'] = KugouLoginCrypto.androidSignature(params, body);
    try {
      final resp = await JXHttp.dio.post(
        'https://loginserviceretry.kugou.com/v7/login_by_verifycode',
        queryParameters: params,
        data: body,
        options: Options(
          contentType: 'application/json',
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'support-calm': '1',
            'User-Agent': 'Android16-1070-11440-130-0-LOGIN-wifi',
          },
        ),
      );
      _collectSetCookies(resp.headers);
      final root = resp.data is Map ? resp.data as Map : null;
      if (root == null) {
        _lastError = '酷狗登录返回空响应（接口可能已变更）';
        return null;
      }
      final status = (root['status'] as num?)?.toInt() ?? 0;
      if (status != 1) {
        final msg =
            '${root['data'] is String ? root['data'] : (root['msg'] ?? root['message'] ?? '')}'
                .trim();
        final errCode = '${root['error_code'] ?? ''}'.trim();
        String hint = '';
        // pk 修复后业务错误码可信：20006 验证码错误 / 20020 验证码过期
        if (errCode == '20006' || errCode == '20020') {
          hint = '。验证码错误或已过期，请重新获取后尽快输入';
        } else if (errCode == '34175') {
          hint = '。该手机号绑定了多个酷狗账号，请改用扫码登录';
        } else if (errCode == '20028' ||
            (resp.headers.value('ssa-code') ?? '').isNotEmpty) {
          hint = '。触发酷狗风控验证，请稍后重试或改用扫码登录';
        }
        _lastError = '酷狗验证码登录失败：'
            '${msg.isNotEmpty ? msg : 'status=$status'}'
            '${errCode.isEmpty ? '' : '（error_code=$errCode）'}$hint';
        return null;
      }
      final data = root['data'] is Map ? root['data'] as Map : null;
      final secuParams = '${data?['secu_params'] ?? ''}';
      if (secuParams.isEmpty) {
        _lastError = '酷狗登录成功但未返回令牌（secu_params 缺失）';
        return null;
      }
      // secu_params 用同一 tempKey 解密：可能是 JSON（多键）或纯文本 token
      var plain = '';
      try {
        plain = KugouLoginCrypto.aesDecryptHex(secuParams, tempKey);
      } catch (_) {}
      Object? tokenInfo;
      try {
        tokenInfo = jsonDecode(plain);
      } catch (_) {
        tokenInfo = plain;
      }
      final tokenMap =
          tokenInfo is Map ? Map<String, dynamic>.from(tokenInfo) : null;
      final token =
          '${tokenMap?['token'] ?? (tokenInfo is String ? tokenInfo : '')}'
              .trim();
      if (token.isEmpty) {
        _lastError = '酷狗登录令牌解密失败（协议可能已变更）';
        return null;
      }
      _cookies['token'] = token;
      // 持久化设备 mid（kg_mid），账号歌单等请求与登录共用设备身份
      _cookies['kg_mid'] = mid;
      tokenMap?.forEach((k, v) {
        final value = '$v';
        if (value.isEmpty || k == 'clienttime_ms') return;
        _cookies[k] = value;
      });
      final userid =
          '${data?['userid'] ?? tokenMap?['userid'] ?? ''}'.trim();
      if (userid.isNotEmpty) _cookies['userid'] = userid;
      final t1 = '${data?['t1'] ?? ''}'.trim();
      if (t1.isNotEmpty) _cookies['t1'] = t1;
      final vipType = '${data?['vip_type'] ?? ''}'.trim();
      if (vipType.isNotEmpty) _cookies['vip_type'] = vipType;
      final vipToken = '${data?['vip_token'] ?? ''}'.trim();
      if (vipToken.isNotEmpty) _cookies['vip_token'] = vipToken;
      var nickname =
          '${tokenMap?['nickname'] ?? tokenMap?['nick_name'] ?? data?['nickname'] ?? ''}'
              .trim();
      if (nickname.isEmpty) nickname = '酷狗用户';
      final pic = tokenMap?['pic'] ?? tokenMap?['headimg'] ?? data?['pic'];
      _lastError = null;
      return AccountSession(
        platform: platform,
        cookies: Map.of(_cookies),
        nickname: nickname,
        avatarUrl:
            pic is String && pic.isNotEmpty ? jxNormalizeImageUrl(pic) : null,
      );
    } catch (e) {
      _lastError = _describeError(e, '酷狗验证码登录失败');
      return null;
    }
  }
}
