// ignore_for_file: avoid_print
// 酷狗登录态假设验证探针（联网，手动运行；输出脱敏）。
//
// 目的：在改 App 代码之前，用**用户当前的真实 token**验证以下假设：
//   H1 现在扫码得到的 token+userid 是否已是完整登录态（能取链/能拿 VIP 信息）；
//   H2 `v5/login_by_token`（Android 签名 + 固定 AES key/iv）是否可用（刷新 + 拿
//      vip_type/vip_token/t1）；
//   H3 `v6/priv_url` 取链是否需要真实 dfid（register_dev 注册）与 1001/1005 appid 体系；
//   H4 旧 `m.kugou.com/app/i/getSongInfo.php` 带登录 cookie 是否还能返回直链。
//
// 用法（token 只在本机命令行传入，不写盘）：
//   dart run tool/check_kg_login_state.dart --token=XXX --userid=123456
//     [--dfid=xxx] [--mid=xxx] [--guid=xxx] [--hash=<歌曲hash>] [--keyword=晴天]
//
// 输出：每一步的 HTTP 状态、业务 status/error_code、关键字段（token/vip 值打码）。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/kg_crypto.dart';

const String _androidUa =
    'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';
const String _androidSalt = KgCrypto.androidSalt;
const String _gateway = 'https://gateway.kugou.com';
const String _clientver = '20489';
const String _appidAndroid = '1005'; // gateway/login.user 的默认 appid

String mask(String? v, {int keep = 4}) {
  if (v == null || v.isEmpty) return '(空)';
  if (v.length <= keep * 2) return 'len=${v.length}';
  return '${v.substring(0, keep)}…${v.substring(v.length - keep)}(len=${v.length})';
}

Map<String, String> parseArgs(List<String> args) {
  final out = <String, String>{};
  for (final a in args) {
    if (!a.startsWith('--')) continue;
    final eq = a.indexOf('=');
    if (eq < 0) continue;
    out[a.substring(2, eq)] = a.substring(eq + 1);
  }
  return out;
}

Map<String, String> cookieMap(String token, String userid, String dfid,
        String mid, String guid) =>
    {
      if (token.isNotEmpty) 'token': token,
      if (userid.isNotEmpty) 'userid': userid,
      if (dfid.isNotEmpty) 'dfid': dfid,
      if (mid.isNotEmpty) 'KUGOU_API_MID': mid,
      if (guid.isNotEmpty) 'KUGOU_API_GUID': guid,
    };

String cookieHeader(Map<String, String> cookies) =>
    cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

/// 公共默认参数（对应参考实现 request.js defaultParams）
Map<String, String> defaultParams(
        {required Map<String, String> cookies,
        String? appid,
        String? clientver}) =>
    {
      'dfid': cookies['dfid'] ?? '-',
      'mid': cookies['KUGOU_API_MID'] ?? '',
      'uuid': '-',
      'appid': appid ?? _appidAndroid,
      'clientver': clientver ?? _clientver,
      'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      if ((cookies['token'] ?? '').isNotEmpty) 'token': cookies['token']!,
      if ((cookies['userid'] ?? '').isNotEmpty &&
          cookies['userid'] != '0')
        'userid': cookies['userid']!,
    };

Options _androidHeaders(Map<String, String> cookies,
    {String? router, String? extraUa}) {
  final headers = <String, String>{
    'User-Agent': extraUa ?? _androidUa,
    'dfid': cookies['dfid'] ?? '-',
    'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    'mid': cookies['KUGOU_API_MID'] ?? '',
    'kg-rc': '1',
    'kg-thash': '5d816a0',
    'kg-rec': '1',
    'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
    'Cookie': cookieHeader(cookies),
  };
  if (router != null) headers['x-router'] = router;
  return Options(
    headers: headers,
    contentType: Headers.jsonContentType,
    validateStatus: (s) => s != null && s < 500,
    receiveTimeout: const Duration(seconds: 15),
  );
}

/// Web 请求（登录相关域）
Future<Response<dynamic>> webGet(
    String url, Map<String, String> params, Map<String, String> cookies) {
  final signed = {...params};
  signed['signature'] = KgCrypto.signWeb(signed);
  return JXHttp.dio.get(url,
      queryParameters: signed,
      options: Options(
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
          'Referer': 'https://login-user.kugou.com/',
          if (cookies.isNotEmpty) 'Cookie': cookieHeader(cookies),
        },
        validateStatus: (s) => s != null && s < 500,
        receiveTimeout: const Duration(seconds: 15),
      ));
}

/// register_dev：注册真实 dfid（AES 密封 body + RSA 包装 p + register 签名）
Future<String?> registerDevice(Map<String, String> cookies,
    {String? guid, bool withAuth = true}) async {
  final dataMap = <String, Object?>{
    'availableRamSize': 4983533568,
    'availableRomSize': 48114719,
    'availableSDSize': 48114717,
    'basebandVer': '',
    'batteryLevel': 100,
    'batteryStatus': 3,
    'brand': 'Redmi',
    'buildSerial': 'unknown',
    'device': 'marble',
    'imei': guid ?? cookies['KUGOU_API_GUID'] ?? '',
    'imsi': '',
    'manufacturer': 'Xiaomi',
    'uuid': guid ?? cookies['KUGOU_API_GUID'] ?? '',
    'accelerometer': false,
    'accelerometerValue': '',
    'gravity': false,
    'gravityValue': '',
    'gyroscope': false,
    'gyroscopeValue': '',
    'light': false,
    'lightValue': '',
    'magnetic': false,
    'magneticValue': '',
    'orientation': false,
    'orientationValue': '',
    'pressure': false,
    'pressureValue': '',
    'step_counter': false,
    'step_counterValue': '',
    'temperature': false,
    'temperatureValue': '',
  };
  final aes = KgCrypto.playlistAesEncrypt(dataMap);
  final userid = cookies['userid'] ?? '0';
  final token = cookies['token'] ?? '';
  final p = KgCrypto.rsaPkcs1EncryptHex(
      jsonEncode({'aes': aes.key, 'uid': userid, 'token': token}));
  final base = defaultParams(cookies: cookies);
  if (!withAuth) {
    base.remove('token');
    base.remove('userid');
  }
  final params = <String, String>{
    ...base,
    'part': '1',
    'platid': '1',
    'p': p,
  };
  params['signature'] = KgCrypto.signRegister(params);
  try {
    final resp = await JXHttp.dio.post(
        'https://userservice.kugou.com/risk/v3/r_register_dev',
        data: aes.str,
        queryParameters: params,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'User-Agent': _androidUa,
            'dfid': cookies['dfid'] ?? '-',
            'mid': cookies['KUGOU_API_MID'] ?? '',
            'clienttime': params['clienttime']!,
            'Cookie': cookieHeader(cookies),
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 15),
        ));
    final bytes = resp.data is List<int>
        ? resp.data as List<int>
        : const <int>[];
    final ct = resp.headers.value('content-type') ?? '-';
    final preview = utf8.decode(bytes.take(80).toList(), allowMalformed: true);
    final bodyB64 = base64Encode(bytes);
    Map<String, dynamic> decoded;
    try {
      decoded = KgCrypto.playlistAesDecrypt(bodyB64, aes.key);
    } catch (e) {
      print('[register_dev] 解密失败：$e HTTP=${resp.statusCode} '
          'content-type=$ct bytes=${bytes.length} preview=${mask(preview, keep: 20)}');
      return null;
    }
    final status = decoded['status'];
    final data = decoded['data'];
    final dfid = data is Map ? '${data['dfid'] ?? ''}' : '';
    print('[register_dev] HTTP=${resp.statusCode} status=$status '
        'error_code=${decoded['error_code']} dfid=${mask(dfid)}');
    if ('$status' == '1' && dfid.isNotEmpty) return dfid;
    return null;
  } catch (e) {
    print('[register_dev] 异常：$e');
    return null;
  }
}

/// v5/login_by_token：刷新 token 并取 vip_type/vip_token/t1
Future<Map<String, dynamic>?> loginByTokenV5(
    Map<String, String> cookies) async {
  const key = '90b8382a1bb4ccdcf063102053fd75b8';
  const iv = 'f063102053fd75b8';
  final token = cookies['token'] ?? '';
  if (token.isEmpty) {
    print('[v5/login_by_token] 跳过：无 token');
    return null;
  }
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final nowSec = nowMs ~/ 1000;
  final p3 = KgCrypto.aesCbcEncryptHex(
      jsonEncode({'clienttime': nowSec, 'token': token}), key, iv);
  final temp = KgCrypto.randomString(16).toLowerCase();
  final keyIv = KgCrypto.md5KeyIv(temp);
  final emptyEnc = KgCrypto.aesCbcEncryptHex('{}', keyIv.key, keyIv.iv);
  final pk = KgCrypto.rsaRawEncryptHex(
      jsonEncode({'clienttime_ms': nowMs, 'key': temp}));
  final dataMap = <String, Object?>{
    'dfid': cookies['dfid'] ?? '-',
    'p3': p3,
    'plat': 1,
    't1': 0,
    't2': 0,
    't3': 'MCwwLDAsMCwwLDAsMCwwLDA=',
    'pk': pk,
    'params': emptyEnc,
    'userid': cookies['userid'] ?? '0',
    'clienttime_ms': nowMs,
  };
  final body = jsonEncode(dataMap);
  final params = defaultParams(cookies: cookies);
  params['signature'] = KgCrypto.signAndroid(params, body);
  try {
    final resp = await JXHttp.dio.post(
        'http://login.user.kugou.com/v5/login_by_token',
        data: body,
        queryParameters: params,
        options: Options(
          headers: {
            'User-Agent': _androidUa,
            'dfid': cookies['dfid'] ?? '-',
            'mid': cookies['KUGOU_API_MID'] ?? '',
            'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
            'kg-rc': '1',
            'kg-thash': '5d816a0',
            'Cookie': cookieHeader(cookies),
            'Content-Type': 'application/json',
          },
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 15),
        ));
    final root = resp.data is Map ? resp.data as Map : const {};
    final status = root['status'];
    print('[v5/login_by_token] HTTP=${resp.statusCode} status=$status '
        'error_code=${root['error_code']} msg=${root['error_msg'] ?? ''}');
    final data = root['data'];
    if (data is Map) {
      final secu = '${data['secu_params'] ?? ''}';
      final merged = <String, dynamic>{...data};
      if (secu.isNotEmpty) {
        try {
          final plain = KgCrypto.aesCbcDecryptHex(secu, keyIv.key, keyIv.iv);
          final decoded = jsonDecode(plain);
          if (decoded is Map) merged.addAll(decoded.cast<String, dynamic>());
        } catch (e) {
          print('[v5/login_by_token] secu_params 解密失败：$e');
        }
      }
      print('[v5/login_by_token] token=${mask('${merged['token'] ?? ''}')} '
          'userid=${merged['userid']} vip_type=${merged['vip_type']} '
          'vip_token=${mask('${merged['vip_token'] ?? ''}')} '
          't1=${mask('${merged['t1'] ?? ''}')}');
      return merged;
    }
    return null;
  } catch (e) {
    print('[v5/login_by_token] 异常：$e');
    return null;
  }
}

/// v6/priv_url：Android 签名取播放直链
Future<List<Map<String, dynamic>>> fetchPrivUrl(
    String hash, Map<String, String> cookies) async {
  final token = cookies['token'] ?? '';
  final userid = cookies['userid'] ?? '0';
  final dfid = (cookies['dfid'] ?? '').isEmpty || cookies['dfid'] == '-'
      ? KgCrypto.randomString(24).toUpperCase()
      : cookies['dfid']!;
  final vipToken = cookies['vip_token'] ?? '';
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final signKey = KgCrypto.md5Hex(
      '${hash}185672dd44712f60bb1736df5a377e82$_appidAndroid${cookies['KUGOU_API_MID']}$userid');
  final dataMap = <String, Object?>{
    'area_code': '1',
    'behavior': 'play',
    'qualities': [
      '128', '320', 'flac', 'high', 'multitrack',
      'viper_atmos', 'viper_tape', 'viper_clear', 'super'
    ],
    'resource': {
      'album_audio_id': 0,
      'collect_list_id': '3',
      'collect_time': nowMs,
      'hash': hash,
      'id': 0,
      'page_id': 1,
      'type': 'audio',
    },
    'token': token,
    'tracker_param': {
      'all_m': 1,
      'auth': '',
      'is_free_part': 0,
      'key': signKey,
      'module_id': 0,
      'need_climax': 1,
      'need_xcdn': 1,
      'open_time': '',
      'pid': '411',
      'pidversion': '3001',
      'priv_vip_type': '6',
      'viptoken': vipToken,
    },
    'userid': userid,
    'vip': int.tryParse('') ?? 0,
  };
  final body = jsonEncode(dataMap);
  final params = defaultParams(cookies: cookies);
  params['signature'] = KgCrypto.signAndroid(params, body);
  try {
    final resp = await JXHttp.dio.post('$_gateway/v6/priv_url',
        data: body,
        queryParameters: params,
        options: _androidHeaders({...cookies, 'dfid': dfid},
            router: 'tracker.kugou.com'));
    final root = resp.data is Map ? resp.data as Map : const {};
    final urls = root['url'] ?? root['data'];
    final list = <Map<String, dynamic>>[];
    if (urls is List) {
      for (final item in urls) {
        if (item is Map) list.add(item.cast<String, dynamic>());
      }
    }
    print('[v6/priv_url] HTTP=${resp.statusCode} status=${root['status']} '
        'error_code=${root['error_code']} '
        'msg=${root['error_msg'] ?? root['msg'] ?? ''} '
        'urlCount=${list.length}');
    for (final u in list.take(4)) {
      print('  quality=${u['quality'] ?? u['level']} '
          'url=${mask('${u['url'] ?? ''}', keep: 30)}');
    }
    return list;
  } catch (e) {
    print('[v6/priv_url] 异常：$e');
    return const [];
  }
}

/// 轻量用户信息接口（参考 module/user_info.js）：验证 token+userid 是否是有效登录态
Future<void> fetchUserInfo(Map<String, String> cookies) async {
  final token = cookies['token'] ?? '';
  final userid = cookies['userid'] ?? '0';
  final mid = cookies['KUGOU_API_MID'] ?? '';
  final clienttime = DateTime.now().millisecondsSinceEpoch;
  final p = KgCrypto.rsaRawEncryptHex(
      jsonEncode({'clienttime': clienttime, 'token': token}));
  final dataMap = <String, Object?>{
    'p': p,
    'appid': _appidAndroid,
    'mid': mid,
    'clientver': _clientver,
    'source': 0,
    'clienttime': clienttime,
    'uuid': '-',
    'userid': int.tryParse(userid) ?? 0,
    'key': KgCrypto.md5Hex('$_appidAndroid$_androidSalt$_clientver$clienttime'),
  };
  final body = jsonEncode(dataMap);
  final params = defaultParams(cookies: cookies);
  params['signature'] = KgCrypto.signAndroid(params, body);
  try {
    final resp = await JXHttp.dio.post(
        'http://relation.user.kugou.com/v1/get_my_userinfo',
        data: body,
        queryParameters: params,
        options: Options(
          headers: {
            'User-Agent': _androidUa,
            'Host': 'relation.user.kugou.com',
            'Cookie': cookieHeader(cookies),
            'Content-Type': 'application/json',
          },
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 15),
        ));
    final root = resp.data is Map ? resp.data as Map : const {};
    final data = root['data'];
    final nickname = data is Map ? '${data['nickname'] ?? ''}' : '';
    final vipType = data is Map ? data['vip_type'] : null;
    final vipTokenLen = data is Map
        ? '${data['vip_token'] ?? ''}'.length
        : 0;
    print('[user_info] HTTP=${resp.statusCode} status=${root['status']} '
        'error_code=${root['error_code']} nickname=${mask(nickname)} '
        'vip_type=$vipType vip_token_len=$vipTokenLen '
        'userid=${data is Map ? data['userid'] : '-'}');
  } catch (e) {
    print('[user_info] 异常：$e');
  }
}

/// 旧接口：m.kugou getSongInfo（带登录 cookie）
Future<void> legacySongInfo(String hash, Map<String, String> cookies) async {
  try {
    final resp = await JXHttp.dio.get(
        'https://m.kugou.com/app/i/getSongInfo.php',
        queryParameters: {'cmd': 'playInfo', 'hash': hash, 'platid': 4},
        options: Options(
          headers: {
            'Cookie': cookieHeader(cookies),
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/126',
          },
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 15),
        ));
    final root = resp.data is Map ? resp.data as Map : const {};
    print('[legacy getSongInfo] HTTP=${resp.statusCode} '
        'status=${root['status']} error=${root['error']} '
        'url=${mask('${root['url'] ?? ''}', keep: 30)} '
        'privilege=${root['privilege']}');
  } catch (e) {
    print('[legacy getSongInfo] 异常：$e');
  }
}

/// v5/url（GET，带 signKey）取链——参考 module/song_url.js
Future<void> fetchV5Url(String hash, Map<String, String> cookies) async {
  final userid = cookies['userid'] ?? '0';
  final mid = cookies['KUGOU_API_MID'] ?? '';
  final signKey =
      KgCrypto.md5Hex('${hash}57ae12eb6890223e355ccfcb74edf70d$_appidAndroid$mid$userid');
  final params = <String, String>{
    ...defaultParams(cookies: cookies),
    'album_id': '0',
    'area_code': '1',
    'hash': hash.toLowerCase(),
    'ssa_flag': 'is_fromtrack',
    'version': '11430',
    'page_id': '151369488',
    'quality': '128',
    'album_audio_id': '0',
    'behavior': 'play',
    'pid': '2',
    'cmd': '26',
    'pidversion': '3001',
    'IsFreePart': '0',
    'ppage_id': '463467626,350369493,788954147',
    'cdnBackup': '1',
    'module': '',
    'key': signKey,
  };
  params['signature'] = KgCrypto.signAndroid(params);
  try {
    final resp = await JXHttp.dio.get('$_gateway/v5/url',
        queryParameters: params,
        options: _androidHeaders(
            {...cookies, 'dfid': KgCrypto.randomString(24).toUpperCase()},
            router: 'trackercdn.kugou.com'));
    final root = resp.data is Map ? resp.data as Map : const {};
    final urls = root['url'];
    final count = urls is List ? urls.length : 0;
    print('[v5/url] HTTP=${resp.statusCode} status=${root['status']} '
        'error_code=${root['error_code']} urlCount=$count');
    if (urls is List) {
      for (final u in urls.take(2)) {
        if (u is Map) {
          print('  quality=${u['quality']} url=${mask('${u['url'] ?? ''}', keep: 30)}');
        }
      }
    }
  } catch (e) {
    print('[v5/url] 异常：$e');
  }
}

/// 匿名搜索返回候选列表（用于挑选免费歌）
Future<List<({String hash, String name, String privilege})>> searchList(
    String keyword) async {
  final out = <({String hash, String name, String privilege})>[];
  try {
    final resp = await JXHttp.dio.get(
        'https://songsearch.kugou.com/song_search_v2',
        queryParameters: {
          'keyword': keyword,
          'page': 1,
          'pagesize': 10,
          'platform': 'PCFilter',
          'tag': 'em',
          'filter': '2',
        },
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
          },
          validateStatus: (s) => s != null && s < 500,
        ));
    final data = resp.data is Map ? resp.data['data'] as Map? : null;
    final lists = (data?['lists'] as List?) ?? const [];
    for (final raw in lists) {
      final m = raw as Map;
      final hash = '${m['FileHash'] ?? ''}';
      if (hash.isEmpty) continue;
      out.add((
        hash: hash,
        name: '${m['SongName'] ?? ''}',
        privilege: '${m['Privilege'] ?? ''}',
      ));
    }
    for (final item in out.take(5)) {
      print('[search] ${item.name} hash=${mask(item.hash, keep: 8)} '
          'privilege=${item.privilege}');
    }
  } catch (e) {
    print('[search] 异常：$e');
  }
  return out;
}

Future<void> main(List<String> args) async {
  final a = parseArgs(args);
  final token = a['token'] ?? Platform.environment['KG_TOKEN'] ?? '';
  final userid = a['userid'] ?? Platform.environment['KG_USERID'] ?? '';
  if (token.isEmpty || userid.isEmpty) {
    print('用法: dart run tool/check_kg_login_state.dart '
        '--token=XXX --userid=123 [--dfid=] [--mid=] [--guid=] '
        '[--hash=] [--keyword=晴天]');
    exitCode = 2;
    return;
  }
  var guid = a['guid'] ?? a['KUGOU_API_GUID'] ?? '';
  var mid = a['mid'] ?? a['KUGOU_API_MID'] ?? '';
  var dfid = a['dfid'] ?? '';
  if (guid.isEmpty) guid = KgCrypto.randomGuid();
  if (mid.isEmpty) mid = KgCrypto.calculateMid(guid);
  var cookies = cookieMap(token, userid, dfid, mid, guid);
  print('=== 输入(脱敏) ===');
  print('token=${mask(token)} userid=${mask(userid)} '
      'dfid=${mask(dfid)} mid=${mask(mid)} guid=${mask(guid)}');

  print('');
  print('=== A) 设备注册（真实 dfid）===');
  var registered = await registerDevice(cookies, guid: guid);
  if (registered == null) {
    print('  带登录态注册失败，改用未登录形态重试一次');
    registered = await registerDevice(cookies, guid: guid, withAuth: false);
  }
  if (registered != null && registered.isNotEmpty) {
    dfid = registered;
    cookies = cookieMap(token, userid, dfid, mid, guid);
  } else {
    print('注册失败，使用传入/随机 dfid 继续（预期 20017/20018/20028 风险）');
  }

  print('');
  print('=== B) v5/login_by_token（刷新 + VIP 字段）===');
  final refreshed = await loginByTokenV5(cookies);
  if (refreshed != null) {
    final newToken = '${refreshed['token'] ?? ''}';
    if (newToken.isNotEmpty) {
      cookies['token'] = newToken;
      print('  使用刷新后的 token 继续后续测试（token=${mask(newToken)}）');
    }
    for (final k in ['vip_type', 'vip_token', 't1', 'userid']) {
      if (refreshed[k] != null) cookies[k] = '${refreshed[k]}';
    }
  }

  print('');
  print('=== C) VIP 权益（union vip）===');
  try {
    final signed = defaultParams(cookies: cookies);
    signed['busi_type'] = 'concept';
    signed['signature'] = KgCrypto.signAndroid(signed);
    final resp = await JXHttp.dio.get('https://kugouvip.kugou.com/v1/get_union_vip',
        queryParameters: signed,
        options: _androidHeaders(cookies));
    final root = resp.data is Map ? resp.data as Map : const {};
    print('[union_vip] HTTP=${resp.statusCode} status=${root['status']} '
        'error_code=${root['error_code']} vip_type=${root['vip_type']} '
        'data=${mask(jsonEncode(root['data']), keep: 60)}');
  } catch (e) {
    print('[union_vip] 异常：$e');
  }

  print('');
  print('=== C2) 用户信息（验证 token+userid 是有效登录态）===');
  await fetchUserInfo(cookies);

  print('');
  print('=== D) 取链测试（v6/priv_url + v5/url + 旧 getSongInfo）===');
  var hash = a['hash'] ?? '';
  var isVipTrack = true;
  if (hash.isEmpty) {
    // 优先选一首免费歌（Privilege<10）验证「普通歌可播」，再测付费歌
    final candidates = await searchList(a['keyword'] ?? '晴天');
    for (final c in candidates) {
      final p = int.tryParse(c.privilege) ?? 0;
      if (p < 10) {
        hash = c.hash;
        isVipTrack = false;
        break;
      }
    }
    if (hash.isEmpty && candidates.isNotEmpty) {
      hash = candidates.first.hash;
      isVipTrack = true;
    }
    print('[search] 选中 hash=${mask(hash, keep: 8)} '
        '免费歌=${!isVipTrack} （用户非 VIP，免费歌必须可播）');
  }
  if (hash.isEmpty) {
    print('未取到 hash，跳过取链测试');
  } else {
    await legacySongInfo(hash, cookies);
    await fetchV5Url(hash, cookies);
    await fetchPrivUrl(hash, cookies);
    if (isVipTrack) {
      print('  注：该曲为付费/VIP 曲，普通账号取链为空属预期（文案需准确）。');
    }
  }

  print('');
  print('=== 结论提示 ===');
  print('· register_dev status=1 → 真实 dfid 可用；否则取链大概率 20028/20018。');
  print('· v5/login_by_token status=1 → token 可刷新、VIP 字段可用；'
      '若 status=0(20006) 说明该 token 协议域不匹配。');
  print('· v6/priv_url 返回 url → 登录态可用于播放；空 url 且 error_code!=0 → 受限。');
}
