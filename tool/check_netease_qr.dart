// 网易云扫码登录协议探针（eapi / AES-128-ECB + 客户端指纹）。
//
// 背景（2026-11-09 真机实扫）：旧实现走 /api/login/qrcode/* 的「web 模拟」登录，
// 手机确认后服务端返回 code=8821「请切换其他登录方式或升级新版本再试」——
// 官方已拒绝 web 模拟扫码，必须像官方客户端一样请求：
//   · URL：POST https://music.163.com/eapi/login/qrcode/unikey  与 .../client/login
//   · body：`params=<AES-128-ECB(明文)>`，明文 = apiPath-36cd479b6b5-json-36cd479b6b5-md5
//     （apiPath 不含 /eapi；md5 = MD5('nobody'+apiPath+'use'+json+'md5forencrypt')）
//   · 请求头带官方客户端 UA + os/appver/deviceId 等 Cookie（unikey 与 poll 同一 deviceId）
//   · type 用字符串 "3"；二维码内容仍是 https://music.163.com/login?codekey=<unikey>
// 参考实现：Yuanlang3/dsh-netease-music-plugin lib/index.js 的 eapiPost/qr-key/qr-check。
//
// 用法：dart run tool/check_netease_qr.dart
// 预期：取码 200 + 27~40 位 unikey，轮询处于 801/802 等待态（无人扫码时不出现 803）。
// 退出码 0 = eapi 协议被服务端接受。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

import 'package:jxmusic/services/api/http.dart';

const String _eapiKey = 'e82ckenh8dichen8'; // 16 字节 ASCII
const String _eapiUa =
    'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)';
const String _pathUnikey = '/api/login/qrcode/unikey';
const String _pathCheck = '/api/login/qrcode/client/login';
const String _urlUnikey = 'https://music.163.com/eapi/login/qrcode/unikey';
const String _urlCheck = 'https://music.163.com/eapi/login/qrcode/client/login';

String md5Hex(String text) => md5.convert(utf8.encode(text)).toString();

/// AES-128-ECB + PKCS7，输出大写 hex（与官方/参考实现一致）
String aesEcbHex(String plainText) {
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

/// eapi 加密：path 不带 /eapi；返回 params 明文 hex
String eapiParams(String apiPath, Map<String, dynamic> data) {
  final text = jsonEncode(data);
  final digest = md5Hex('nobody${apiPath}use${text}md5forencrypt');
  final payload = '$apiPath-36cd479b6b5-$text-36cd479b6b5-$digest';
  return aesEcbHex(payload);
}

/// 官方客户端指纹 Cookie（key/value 都做 URI 编码；unikey 与 poll 用同一 deviceId）
String qrCookieHeader(String deviceId) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final requestId =
      '${nowMs}_${Random().nextInt(1000).toString().padLeft(4, '0')}';
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

String randomDeviceId() {
  final rng = Random.secure();
  const chars = '0123456789ABCDEF';
  return List<String>.generate(52, (_) => chars[rng.nextInt(16)]).join();
}

Future<Response<dynamic>> eapiPost(
    String url, String apiPath, Map<String, dynamic> data, String deviceId) {
  return JXHttp.dio.post(url,
      data: {'params': eapiParams(apiPath, data)},
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (s) => s != null && s < 500,
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent': _eapiUa,
          'Cookie': qrCookieHeader(deviceId),
          'Referer': 'https://music.163.com/',
        },
      ));
}

String mask(String value, {int keep = 4}) {
  if (value.isEmpty) return '(空)';
  if (value.length <= keep * 2) return 'len=${value.length}';
  return '${value.substring(0, keep)}…(len=${value.length})';
}

List<String> cookieNames(Headers headers) =>
    (headers['set-cookie'] ?? const <String>[])
        .map((e) => e.split(';').first.split('=').first.trim())
        .toList();

Future<void> main() async {
  var failed = false;
  final deviceId = randomDeviceId();
  print('=== 0) 自检：AES-128-ECB/params 可生成 ===');
  final sample = eapiParams(_pathUnikey, {'type': '3'});
  print('[self-check] deviceId=${mask(deviceId)} '
      'params(len=${sample.length}, 前16=${sample.substring(0, 16)})');
  if (sample.isEmpty || sample.length % 32 != 0) failed = true;

  print('');
  print('=== 1) eapi 取码（unikey，type="3"）===');
  var key = '';
  try {
    final resp = await eapiPost(_urlUnikey, _pathUnikey, {'type': '3'}, deviceId);
    final body = resp.data is Map ? resp.data as Map : const {};
    key = '${body['unikey'] ?? ''}'.trim();
    print('[unikey] HTTP=${resp.statusCode} code=${body['code']} '
        'message=${body['message'] ?? ''} unikey=${mask(key)} '
        'set-cookie=[${cookieNames(resp.headers).join(',')}]');
    if (resp.statusCode != 200 || key.isEmpty) {
      failed = true;
      print('        取码失败：服务端未返回 unikey');
    }
  } catch (e) {
    failed = true;
    print('[unikey] 异常：$e');
  }

  if (key.isNotEmpty) {
    print('');
    print('=== 2) eapi 轮询（无人扫码，预期 800/801/802 等待态）===');
    for (var i = 1; i <= 3; i++) {
      try {
        final resp = await eapiPost(
            _urlCheck, _pathCheck, {'key': key, 'type': '3'}, deviceId);
        final body = resp.data is Map ? resp.data as Map : const {};
        final code = body['code'];
        print('[poll$i] HTTP=${resp.statusCode} code=$code '
            'message=${body['message'] ?? ''} '
            'set-cookie=[${cookieNames(resp.headers).join(',')}]');
        if ('$code' != '800' && '$code' != '801' && '$code' != '802') {
          failed = true;
          print('        轮询返回了非等待态 code=$code（eapi 协议可能被拒）');
        }
      } catch (e) {
        failed = true;
        print('[poll$i] 异常：$e');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  print('');
  print('=== 3) 对照：旧 /api 端点还接受吗（同 key 跑一次，仅取证）===');
  if (key.isNotEmpty) {
    try {
      final resp = await JXHttp.dio.post(
          'https://music.163.com/api/login/qrcode/client/login',
          data: {'key': key, 'type': '1'},
          options: Options(
            contentType: 'application/x-www-form-urlencoded',
            validateStatus: (s) => s != null && s < 500,
            receiveTimeout: const Duration(seconds: 10),
          ));
      final body = resp.data is Map ? resp.data as Map : const {};
      // 隐私：旧接口 803 可能带完整 cookie，这里只打 code/message，不打整包 body
      print('[old-api] HTTP=${resp.statusCode} code=${body['code']} '
          'message=${body['message'] ?? ''} bodyLen=${jsonEncode(body).length}');
    } catch (e) {
      print('[old-api] 异常：$e');
    }
  }

  print('');
  print(failed
      ? '结果：FAIL（eapi 协议未被接受，见上方输出）'
      : '结果：PASS（eapi 取码成功、轮询处于等待态、协议/加密/指纹被服务端接受）');
  exitCode = failed ? 1 : 0;
}
