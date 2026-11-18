// 酷狗 SSA 风控验证探针：login 触发 20028 → get_verify_info → 观察验证类型。
// 假凭据测试（若 20028 为 IP/设备级风控可复现），仅开发期诊断。
//   dart run tool/kugou_ssa_probe.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:jxmusic/services/api/kugou_login_crypto.dart';

void main(List<String> args) async {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));
  final mid = _randomMidDecimal();
  print('mid=$mid');
  try {
    // 连续多次失败登录，观察是否触发 20028 风控
    List<String>? ssa;
    for (var i = 0; i < 5; i++) {
      print('--- 第 ${i + 1} 次 ---');
      ssa = await _loginByPwd(dio, mid);
      if (ssa != null) break;
    }
    if (ssa == null) {
      print('未触发 20028（或登录意外成功），SSA 链路无需验证');
      return;
    }
    await _getVerifyInfo(dio, mid, ssa);
  } finally {
    dio.close();
  }
}

/// 假凭据密码登录；返回 20028 时的 [ssaCode, sid, edt]，否则 null
Future<List<String>?> _loginByPwd(Dio dio, String mid) async {
  print('=====[1] /v9/login_by_pwd 假凭据（观察是否 20028）=====');
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final clienttime = nowMs ~/ 1000;
  final tempKey = KugouLoginCrypto.randomTempKey();
  final encParams = KugouLoginCrypto.aesEncryptHex(
    jsonEncode(<String, dynamic>{
      'pwd': 'ssa_probe_fake_pw',
      'code': '',
      'clienttime_ms': nowMs,
    }),
    tempKey,
  );
  final pk = KugouLoginCrypto.rsaEncryptHex(
    jsonEncode(<String, dynamic>{'clienttime_ms': nowMs, 'key': tempKey}),
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
    'clienttime': '$clienttime',
  };
  params['signature'] = KugouLoginCrypto.androidSignature(params, body);
  final resp = await dio.post(
    'https://gateway.kugou.com/v9/login_by_pwd',
    queryParameters: params,
    data: body,
    options: Options(
      contentType: 'application/json',
      validateStatus: (s) => s != null && s < 500,
      headers: {
        'x-router': 'login.user.kugou.com',
        'User-Agent': 'Android16-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
      },
    ),
  );
  print('HTTP ${resp.statusCode}');
  print(_pretty(resp.data));
  final root = resp.data is Map ? resp.data as Map : null;
  final errCode = '${root?['error_code'] ?? ''}'.trim();
  final ssaCode =
      '${root?['ssaCode'] ?? resp.headers.value('ssa-code') ?? ''}'.trim();
  final sid = '${root?['sid'] ?? ''}'.trim();
  final edt = '${root?['edt'] ?? ''}'.trim();
  if (errCode == '20028' && ssaCode.isNotEmpty) {
    print('ssaCode=$ssaCode sid=${sid.isEmpty ? '-' : '有'} '
        'edt=${edt.isEmpty ? '-' : '有'}');
    return [ssaCode, sid, edt];
  }
  return null;
}

/// get_verify_info：观察 v_type（23 腾讯滑块 / 32 短信）
Future<void> _getVerifyInfo(Dio dio, String mid, List<String> ssa) async {
  print('=====[2] /verifyservice/v3/get_verify_info=====');
  final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final body = jsonEncode(<String, dynamic>{
    'eventid': ssa[0],
    'userid': 0,
    'platid': 2,
    'rtype': 1,
    'wasm': 1,
    'i': '',
    'sid': '',
    'edt': '',
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
  final resp = await dio.post(
    'https://gateway.kugou.com/verifyservice/v3/get_verify_info',
    queryParameters: params,
    data: body,
    options: Options(
      contentType: 'application/json',
      validateStatus: (s) => s != null && s < 500,
      headers: {
        'User-Agent': 'Android16-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
      },
    ),
  );
  print('HTTP ${resp.statusCode}');
  print(_pretty(resp.data));
  final root = resp.data is Map ? resp.data as Map : null;
  final dataObj = root?['data'];
  final data = dataObj is Map ? dataObj : null;
  final vType = data?['v_type'];
  if (vType != null) {
    print('v_type=$vType'
        '${data?.containsKey('sessionid') == true ? ' sessionid=有' : ''}'
        '${data?.containsKey('txappid') == true ? ' txappid=${data?['txappid']}' : ''}');
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

String _randomMidDecimal() =>
    BigInt.parse(md5.convert(utf8.encode(_randomHex32())).toString(), radix: 16)
        .toString();
