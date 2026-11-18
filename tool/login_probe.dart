// 登录协议诊断探针：从本机直连各平台登录接口，观察真实响应形状。
// 仅用于开发期诊断，不进入应用构建。运行：
//   dart run tool/login_probe.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

import 'package:jxmusic/services/api/kugou_login_crypto.dart';

void main(List<String> args) async {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
  ));
  try {
    if (args.contains('anon')) await probeNeteaseAnon(dio);
    if (args.contains('eapi-realip')) await probeNeteaseEapi(dio, realIp: true);
    if (args.contains('weapi-realip')) await probeNeteaseWeapi(dio, realIp: true);
    if (args.isEmpty) {
      await probeKugou(dio);
      final nmtid = await probeNeteaseEapi(dio);
      // 链式重试：同 deviceId + NMTID 二连发
      final dev = List.generate(32, (i) => '0123456789abcdef'[Random.secure().nextInt(16)]).join();
      final n1 = await probeNeteaseEapi(dio, fixedDeviceId: dev);
      final retryCookies = <String, String>{...n1, ...nmtid};
      if (retryCookies.isNotEmpty) {
        await probeNeteaseEapi(dio, fixedDeviceId: dev, extraCookies: retryCookies);
      } else {
        print('no NMTID captured, skip chained retry');
      }
      await probeNeteaseLinuxapi(dio);
    }
  } catch (e) {
    print('probe crashed: $e');
  }
}

void dump(Response<dynamic> resp) {
  print('HTTP ${resp.statusCode}');
  final sc = resp.headers['set-cookie'];
  print('set-cookie-names: ${sc?.map((e) => e.split(';').first.split('=').first).join(',')}');
  final ssa = resp.headers.map.keys
      .where((k) => k.toLowerCase().contains('ssa'))
      .map((k) => '$k=${resp.headers.value(k)}');
  if (ssa.isNotEmpty) print('ssa-headers: ${ssa.join(' | ')}');
  final body = resp.data;
  final text = body is String ? body : jsonEncode(body);
  print('body: ${text.length > 800 ? '${text.substring(0, 800)}...' : text}');
}

Future<void> probeKugou(Dio dio) async {
  print('=====[1] KuGou /v9/login_by_pwd=====');
  final mid = _midDecimal();
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final tempKey = KugouLoginCrypto.randomTempKey();
  final encParams = KugouLoginCrypto.aesEncryptHex(
    jsonEncode({'pwd': 'test123456', 'code': '', 'clienttime_ms': nowMs}),
    tempKey,
  );
  final pk = KugouLoginCrypto.rsaEncryptHex(
    jsonEncode({'clienttime_ms': nowMs, 'key': tempKey}),
  ).toUpperCase();
  final body = jsonEncode(<String, dynamic>{
    'plat': 1,
    'support_multi': 1,
    'clienttime_ms': nowMs,
    't1': KugouLoginCrypto.t1,
    't2': KugouLoginCrypto.t2,
    't3': KugouLoginCrypto.t3,
    'username': '13800000000',
    'params': encParams,
    'pk': pk,
  });
  final params = <String, String>{
    'dfid': '-',
    'mid': mid,
    'uuid': '-',
    'appid': KugouLoginCrypto.appid,
    'clientver': KugouLoginCrypto.clientver,
    'clienttime': '${nowMs ~/ 1000}',
  };
  params['signature'] = KugouLoginCrypto.androidSignature(params, body);
  try {
    final resp = await dio.post(
      'https://gateway.kugou.com/v9/login_by_pwd',
      queryParameters: params,
      data: body,
      options: Options(
        contentType: 'application/json',
        validateStatus: (s) => s != null && s < 500,
        headers: {
          'x-router': 'login.user.kugou.com',
          'dfid': '-',
          'clienttime': '${nowMs ~/ 1000}',
          'mid': mid,
          'kg-rc': '1',
          'kg-thash': '5d816a0',
          'kg-rec': '1',
          'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
          'User-Agent': 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
        },
      ),
    );
    dump(resp);
  } catch (e) {
    print('kugou probe error: $e');
  }
  print('');
}

String _midDecimal() {
  final rng = Random.secure();
  final hex = List.generate(32, (_) => rng.nextInt(16).toRadixString(16)).join();
  final digest = md5.convert(utf8.encode(hex)).toString();
  return BigInt.parse(digest, radix: 16).toString();
}

Future<void> probeNeteaseWeapi(Dio dio, {bool realIp = false}) async {
  print('=====[2] NetEase weapi /weapi/login/cellphone (realIp=$realIp)=====');
  final enc = _weapi({
    'phone': '13800000000',
    'countrycode': '86',
    'md5_password': md5.convert(utf8.encode('test123456')).toString(),
    'rememberLogin': 'true',
  });
  try {
    final resp = await dio.post(
      'https://music.163.com/weapi/login/cellphone',
      data: 'params=${enc['params']}&encSecKey=${enc['encSecKey']}',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (s) => s != null && s < 500,
        headers: {
          'Referer': 'https://music.163.com/',
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          if (realIp) ..._realIpHeaders(),
        },
      ),
    );
    print('content-type: ${resp.headers.value('content-type')}');
    dump(resp);
  } catch (e) {
    print('netease weapi probe error: $e');
  }
  print('');
}

/// linuxapi 登录：POST /api/linux/forward（key 'rFgB&h#%2?^eDg:Q'，AES-128-ECB）
Future<void> probeNeteaseLinuxapi(Dio dio) async {
  print('=====[5] NetEase linuxapi /api/linux/forward login=====');
  const key = r'rFgB&h#%2?^eDg:Q';
  final object = {
    'method': 'POST',
    'url': 'https://music.163.com/api/login/cellphone',
    'params': {
      'phone': '13800000000',
      'countrycode': '86',
      'md5_password': md5.convert(utf8.encode('test123456')).toString(),
      'rememberLogin': 'true',
    },
  };
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(utf8.encode(key))));
  final plain =
      Uint8List.fromList(utf8.encode(jsonEncode(object)));
  final pad = 16 - (plain.length % 16);
  final padded = Uint8List(plain.length + pad)..setRange(0, plain.length, plain);
  for (var i = plain.length; i < padded.length; i++) {
    padded[i] = pad;
  }
  final out = Uint8List(padded.length);
  for (var offset = 0; offset < padded.length; offset += 16) {
    cipher.processBlock(padded, offset, out, offset);
  }
  final eparams = out
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();
  try {
    final resp = await dio.post(
      'https://music.163.com/api/linux/forward',
      data: 'eparams=$eparams',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (s) => s != null && s < 500,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36',
        },
      ),
    );
    dump(resp);
  } catch (e) {
    print('netease linuxapi probe error: $e');
  }
  print('');
}

/// 随机国内 IP 头（NeteaseCloudMusicApi realIP / randomCNIP 社区做法）
Map<String, String> _realIpHeaders() {
  final rng = Random.secure();
  const blocks = [116, 119, 120, 121, 122, 123, 175, 180, 182, 183, 219, 220, 221, 222, 223];
  final ip =
      '${blocks[rng.nextInt(blocks.length)]}.${rng.nextInt(255)}.${rng.nextInt(255)}.${rng.nextInt(255)}';
  print('(X-Real-IP=$ip)');
  return {'X-Real-IP': ip, 'X-Forwarded-For': ip};
}

/// 匿名令牌注册：POST /weapi/register/anonimous（MUSIC_A 来源）
/// username = base64('${deviceId} ${base64(md5(deviceId ^ key))}')（官方算法）
Future<Map<String, String>> probeNeteaseAnon(Dio dio, {bool verbose = true}) async {
  print('=====[4] NetEase /weapi/register/anonimous (weapi, username)=====');
  final rng = Random.secure();
  final deviceId = List.generate(52, (_) => '0123456789ABCDEF'[rng.nextInt(16)]).join();
  const xorKey = r'3go8&$8*3*3h0k(2)2';
  final xored = String.fromCharCodes(List<int>.generate(
      deviceId.length,
      (i) => deviceId.codeUnitAt(i) ^ xorKey.codeUnitAt(i % xorKey.length)));
  final enc = _weapi({
    'username': base64Encode(utf8.encode(
        '$deviceId ${base64Encode(md5.convert(utf8.encode(xored)).bytes)}')),
  });
  final jar = <String, String>{};
  try {
    final resp = await dio.post(
      'https://music.163.com/weapi/register/anonimous',
      data: 'params=${enc['params']}&encSecKey=${enc['encSecKey']}',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (s) => s != null && s < 500,
        headers: {
          'Referer': 'https://music.163.com/',
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        },
      ),
    );
    dump(resp);
    final body = resp.data is Map ? resp.data as Map : const {};
    print('code=${body['code']}');
    final rawCookie = body['cookie'];
    if (rawCookie is String) {
      for (final part in rawCookie.split(';')) {
        final seg = part.trim();
        final eq = seg.indexOf('=');
        if (eq > 0) jar[seg.substring(0, eq)] = seg.substring(eq + 1);
      }
    }
  } catch (e) {
    print('netease anon probe error: $e');
  }
  print('');
  return jar;
}

Future<Map<String, String>> probeNeteaseEapi(Dio dio,
    {bool realIp = false,
    Map<String, String> extraCookies = const {},
    String? fixedDeviceId}) async {
  print(
      '=====[3] NetEase eapi /eapi/w/login/cellphone (realIp=$realIp extra=${extraCookies.keys.toList()} fixedDev=${fixedDeviceId != null})=====');
  final uri = '/api/w/login/cellphone';
  final rng = Random.secure();
  final deviceId =
      fixedDeviceId ?? List.generate(32, (_) => rng.nextInt(16).toRadixString(16)).join();
  final nowMs = DateTime.now().millisecondsSinceEpoch;
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
    'requestId':
        '${nowMs}_${(rng.nextInt(1000)).toString().padLeft(4, '0')}',
    ...extraCookies,
  };
  final data = <String, dynamic>{
    'type': '1',
    'https': 'true',
    'phone': '13800000000',
    'countrycode': '86',
    'password': md5.convert(utf8.encode('test123456')).toString(),
    'remember': 'true',
    'secureCaptcha': '',
    'e_r': false,
    'header': header,
  };
  final params = _eapi(uri, data);
  final cookie = header.entries
      .map((e) =>
          '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
      .join('; ');
  final nmtid = <String, String>{};
  try {
    final resp = await dio.post(
      'https://interfacepc.music.163.com/eapi/w/login/cellphone',
      data: 'params=$params',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (s) => s != null && s < 500,
        headers: {
          'Cookie': cookie,
          'User-Agent': 'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)',
          if (realIp) ..._realIpHeaders(),
        },
      ),
    );
    dump(resp);
    for (final item in (resp.headers['set-cookie'] ?? const <String>[])) {
      final seg = item.split(';').first;
      final eq = seg.indexOf('=');
      if (eq > 0 && seg.substring(0, eq).trim() == 'NMTID') {
        nmtid['NMTID'] = seg.substring(eq + 1).trim();
      }
    }
  } catch (e) {
    print('netease eapi probe error: $e');
  }
  print('');
  return nmtid;
}

// ---- weapi（与应用内 NeteaseCrypto 同款） ----
const String _aesKey = '0CoJUm6Qyw8W8jud';
const String _iv = '0102030405060708';
const String _rsaModulus =
    '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7';
const String _rsaExponent = '010001';

String _aesCbcB64(String plainText, String key) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      true,
      ParametersWithIV(
        KeyParameter(Uint8List.fromList(utf8.encode(key))),
        Uint8List.fromList(utf8.encode(_iv)),
      ),
    );
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
  return base64Encode(out);
}

Map<String, String> _weapi(Map<String, dynamic> data) {
  final rng = Random.secure();
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final secKey = String.fromCharCodes(
      List.generate(16, (_) => chars.codeUnitAt(rng.nextInt(chars.length))));
  final params =
      _aesCbcB64(_aesCbcB64(jsonEncode(data), _aesKey), secKey);
  final modulus = BigInt.parse(_rsaModulus, radix: 16);
  final exponent = BigInt.parse(_rsaExponent, radix: 16);
  final reversed = String.fromCharCodes(secKey.codeUnits.reversed);
  var m = BigInt.zero;
  for (final byte in utf8.encode(reversed)) {
    m = (m << 8) | BigInt.from(byte);
  }
  final encSecKey =
      m.modPow(exponent, modulus).toRadixString(16).padLeft(256, '0');
  return {'params': params, 'encSecKey': encSecKey};
}

// ---- eapi（NeteaseCloudMusicApi-enhanced util/crypto.js 同款） ----
const String _eapiKey = 'e82ckenh8dichen8';

String _eapi(String url, Map<String, dynamic> data) {
  final text = jsonEncode(data);
  final digest =
      md5.convert(utf8.encode('nobody${url}use${text}md5forencrypt')).toString();
  final payload = '$url-36cd479b6b5-$text-36cd479b6b5-$digest';
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(utf8.encode(_eapiKey))));
  final plain = Uint8List.fromList(utf8.encode(payload));
  final pad = 16 - (plain.length % 16);
  final padded = Uint8List(plain.length + pad)..setRange(0, plain.length, plain);
  for (var i = plain.length; i < padded.length; i++) {
    padded[i] = pad;
  }
  final out = Uint8List(padded.length);
  for (var offset = 0; offset < padded.length; offset += 16) {
    cipher.processBlock(padded, offset, out, offset);
  }
  return out
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();
}
