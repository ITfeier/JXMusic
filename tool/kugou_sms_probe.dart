// 酷狗手机验证码登录协议探针：验证 /v7/send_mobile_code 与
// /v7/login_by_verifycode 的签名/加密/响应形状（KuGouMusicApi main 分支协议）。
// 仅开发期诊断，不进入应用构建。运行：
//   dart run tool/kugou_sms_probe.dart [send|login|both]
// 注意：send 模式默认用无效号码（不会真实发短信），仅验证协议链路。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:jxmusic/services/api/kugou_login_crypto.dart';

void main(List<String> args) async {
  final mode = args.isEmpty ? 'both' : args.first;
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));
  final mid = _randomMidDecimal();
  print('mid=$mid dfid=- appid=${KugouLoginCrypto.appid} '
      'clientver=${KugouLoginCrypto.clientver}');
  try {
    if (mode == 'send' || mode == 'both') await _probeSend(dio, mid);
    if (mode == 'login' || mode == 'both') await _probeLogin(dio, mid);
  } finally {
    dio.close();
  }
}

Future<void> _probeSend(Dio dio, String mid) async {
  print('=====[1] KuGou /v7/send_mobile_code (无效号码，验证签名链路)=====');
  final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // 无效号码：期望返回业务错误（手机号格式/不存在），而非签名/参数错误
  final body = jsonEncode(<String, dynamic>{
    'businessid': 5,
    'mobile': '12345',
    'plat': 3,
  });
  final params = <String, String>{
    'dfid': '-',
    'mid': mid,
    'uuid': '-',
    'appid': KugouLoginCrypto.appid,
    'clientver': KugouLoginCrypto.clientver,
    'clienttime': '$clienttime',
  };
  params['signature'] = KugouLoginCrypto.androidSignature(params, body);
  try {
    final resp = await dio.post(
      'https://gateway.kugou.com/v7/send_mobile_code',
      queryParameters: params,
      data: body,
      options: Options(
        contentType: 'application/json',
        validateStatus: (s) => s != null && s < 500,
        headers: {
          'x-router': 'login.user.kugou.com',
          'User-Agent': 'Android16-1070-11440-130-0-LOGIN-wifi',
        },
      ),
    );
    print('HTTP ${resp.statusCode}');
    print(_pretty(resp.data));
  } catch (e) {
    print('send probe error: $e');
  }
}

Future<void> _probeLogin(Dio dio, String mid) async {
  print('=====[2] KuGou /v7/login_by_verifycode (假码，验证协议链路)=====');
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final clienttime = nowMs ~/ 1000;
  final tempKey = KugouLoginCrypto.randomTempKey();
  final encParams = KugouLoginCrypto.aesEncryptHex(
    jsonEncode(<String, dynamic>{'mobile': '13800000000', 'code': '000000'}),
    tempKey,
  );
  const phone = '13800000000';
  final masked =
      '${phone.substring(0, 2)}*****${phone.substring(10, 11)}';
  final pk = KugouLoginCrypto.rsaEncryptHex(
    jsonEncode(<String, dynamic>{'clienttime_ms': nowMs, 'key': tempKey}),
  ).toUpperCase();
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
    'dfid': '-',
    'mid': mid,
    'uuid': '-',
    'appid': KugouLoginCrypto.appid,
    'clientver': KugouLoginCrypto.clientver,
    'clienttime': '$clienttime',
  };
  params['signature'] = KugouLoginCrypto.androidSignature(params, body);
  try {
    final resp = await dio.post(
      'https://loginserviceretry.kugou.com/v7/login_by_verifycode',
      queryParameters: params,
      data: body,
      options: Options(
        contentType: 'application/json',
        validateStatus: (s) => s != null && s < 500,
        headers: {
          'support-calm': '1',
          'User-Agent': 'Android16-1070-11440-130-0-LOGIN-wifi',
        },
      ),
    );
    print('HTTP ${resp.statusCode}');
    print(_pretty(resp.data));
  } catch (e) {
    print('login probe error: $e');
  }
}

String _pretty(Object? data) {
  if (data is Map || data is List) {
    const encoder = JsonEncoder.withIndent('  ');
    try {
      return encoder.convert(data);
    } catch (_) {}
  }
  return '$data';
}

String _randomHex32() {
  final rng = Random.secure();
  const chars = '0123456789abcdef';
  return List<String>.generate(32, (_) => chars[rng.nextInt(16)]).join();
}

String _randomMidDecimal() {
  final digest = md5.convert(utf8.encode(_randomHex32())).toString();
  return BigInt.parse(digest, radix: 16).toString();
}

// 保留 import 引用（Uint8List 由 kugou_login_crypto 传递使用）
// ignore: unused_element
final Uint8List _keepAlive = Uint8List(0);
