// ignore_for_file: avoid_print
// 临时探测脚本：酷狗 `login_by_token_get` 端点可达性 + 加密参数格式（不联网扫码、无真实 token）
//
// 用法：dart run tool/check_kg_token_get.dart
// 能证明什么：
//   1. 端点 HTTP 200 可达、GET 可用（与官网 kguser.v2.min.js 的 QRCodeLogin 链路一致）；
//   2. 我们的 RSA(pk)/AES(params) 封装 + 签名参数能被服务端接受：
//      携带 pk/params 时返回业务错误 error_code=20006（token 无效/登录态失败），
//      而不带 pk/params 时返回 error_code=20010（参数错误）——两者不同即证明参数结构正确。
// 不能证明什么：没有真机扫码拿到的真实 token，status==1 的成功响应与 secu_params
//   解密无法端到端验证。
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:jxmusic/services/api/kg_crypto.dart';
import 'package:jxmusic/services/api/kugou_api.dart';

const _salt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
const _crossBase = 'https://loginservice.kugou.com/';
const _referer = 'https://login-user.kugou.com/login/?appid=1014';

String _md5Hex(String text) => md5.convert(utf8.encode(text)).toString();

/// 与 lib/services/api/kugou_api.dart `_sign()` 相同的 Web 登录签名
Map<String, String> _sign(Map<String, String> input) {
  final params = Map<String, String>.of(input);
  params['srcappid'] ??= '2919';
  params['clientver'] ??= '20000';
  params['clienttime'] ??=
      '${DateTime.now().millisecondsSinceEpoch}';
  params['mid'] ??= '${DateTime.now().millisecondsSinceEpoch}';
  params['uuid'] ??= '${DateTime.now().millisecondsSinceEpoch}';
  params['dfid'] ??= '-';
  final keys = params.keys.toList()..sort();
  final joined = keys.map((k) => '$k=${params[k]}').join();
  params['signature'] = _md5Hex('$_salt$joined$_salt').toUpperCase();
  return params;
}

String _randomHex32() {
  final rng = Random.secure();
  return List<String>.generate(
      32, (_) => rng.nextInt(16).toRadixString(16)).join();
}

final _dio = Dio(BaseOptions(
  headers: {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    'Referer': _referer,
    'Accept': 'application/json, text/javascript, */*; q=0.01',
  },
  responseType: ResponseType.plain,
  validateStatus: (_) => true,
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 15),
));

/// 构造一次 login_by_token_get 请求参数（假 token，仅验证协议结构）
///
/// 与 `lib/services/api/kugou_api.dart` 的 `_loginByToken` 三套候选一致：
/// - aesConvention: 'web'（官网 Web JS 原始 key）| 'md5'（makcre/PEM 约定）
/// - paramStyle: 'webjs'（clientver=1000、clienttime=秒，与官网 JS 一致）|
///   'lead'（clientver=8131、clienttime=毫秒，本项目既有参数）
Map<String, String> _buildQuery(
  String convention, {
  required String userid,
  required String fakeToken,
  String paramStyle = 'lead',
  bool includeCrypto = true,
}) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final mid = _randomHex32();
  final tempKey = KgCrypto.randomKey16();
  final keyIv = convention == 'md5'
      ? KgCrypto.md5KeyIv(tempKey)
      : KgCrypto.webKeyIv(tempKey);
  final modulus = convention == 'md5'
      ? KgCrypto.pemPublicKeyModulusHex()
      : KgCrypto.webPublicModulusHex;
  final params = KgCrypto.aesCbcEncryptHex(
    jsonEncode(<String, String>{'token': fakeToken}),
    keyIv.key,
    keyIv.iv,
  );
  final pk = KgCrypto.rsaRawEncryptHex(
    jsonEncode(<String, Object>{'clienttime_ms': nowMs, 'key': tempKey}),
    modulusHex: modulus,
  );
  final query = <String, String>{
    'appid': '1014',
    'clientver': paramStyle == 'webjs' ? '1000' : '8131',
    'clienttime': paramStyle == 'webjs' ? '${nowMs ~/ 1000}' : '$nowMs',
    'clienttime_ms': '$nowMs',
    'dev': 'web',
    'dfid': '-',
    'mid': mid,
    'uuid': mid,
    'userid': userid,
    'plat': '4',
    'pk': pk,
    'params': params,
  };
  if (!includeCrypto) {
    query.remove('pk');
    query.remove('params');
  }
  return _sign(query);
}

Future<void> _call(String label, Map<String, String> query) async {
  try {
    final resp = await _dio.get(
      '${_crossBase}v1/login_by_token_get',
      queryParameters: query,
    );
    final body = '${resp.data}';
    print('[$label] HTTP ${resp.statusCode} body=${body.length > 240 ? '${body.substring(0, 240)}...' : body}');
    if (resp.statusCode != 200) {
      print('[$label] 非 200，端点可能已变更');
    }
  } catch (e) {
    print('[$label] EXC: $e');
  }
}

Future<void> main() async {
  final fakeToken = _randomHex32();
  print('========== 酷狗 login_by_token_get 端点探测（无真实 token）==========');
  print('fake token = $fakeToken (仅用于观察服务端错误码，不是有效登录凭证)');

  // 0) 加密管线自检：RSA 输出长度、AES 可解密回原文
  for (final convention in ['md5', 'web']) {
    final tempKey = 'abcdefghijklmnop';
    final keyIv = convention == 'md5'
        ? KgCrypto.md5KeyIv(tempKey)
        : KgCrypto.webKeyIv(tempKey);
    final plain = jsonEncode(<String, String>{'token': fakeToken});
    final cipher = KgCrypto.aesCbcEncryptHex(plain, keyIv.key, keyIv.iv);
    final back = KgCrypto.aesCbcDecryptHex(cipher, keyIv.key, keyIv.iv);
    final modulus = convention == 'md5'
        ? KgCrypto.pemPublicKeyModulusHex()
        : KgCrypto.webPublicModulusHex;
    final pk = KgCrypto.rsaRawEncryptHex(
      jsonEncode(<String, Object>{
        'clienttime_ms': DateTime.now().millisecondsSinceEpoch,
        'key': tempKey,
      }),
      modulusHex: modulus,
    );
    print('[self-check $convention] AES 往返一致=${back == plain} '
        'paramsHexLen=${cipher.length} pkHexLen=${pk.length} '
        'modulusHexLen=${modulus.length}');
  }

  // 1) 三套候选约定（与 kugou_api.dart 的候选顺序一致）+ 真实签名参数
  await _call('candidate-1 web-js（含 pk+params）',
      _buildQuery('web', userid: '0', fakeToken: fakeToken, paramStyle: 'webjs'));
  await _call('candidate-2 web-js-lead-params（含 pk+params）',
      _buildQuery('web', userid: '0', fakeToken: fakeToken));
  await _call('candidate-3 makcre-md5-pem（含 pk+params）',
      _buildQuery('md5', userid: '0', fakeToken: fakeToken));

  // 2) 对照组：不带 pk/params → 期望 20010（参数错误），与 20006 区分
  final missing = _buildQuery('md5',
      userid: '0', fakeToken: fakeToken, includeCrypto: false);
  await _call('token_get/control（无 pk+params）', missing);

  // 3) 离线行为冒烟：KuGouApi 对非法 key 的轮询不抛异常
  final api = KuGouApi();
  final bogus = await api.pollQrLogin('bogus-key-not-created');
  print('[KuGouApi.pollQrLogin("bogus-key")] => ${bogus == null ? 'null(符合预期，不抛异常)' : '意外返回 session'}');

  print('========== 结论 ==========');
  print('期望：三套候选（均含 pk+params）HTTP 200 且 error_code=20006（业务失败=token 无效），');
  print('      对照组无 pk/params 返回 error_code=20010（参数错误）→ 说明加密/签名参数结构被接受。');
  print('未验证：status==1 的成功响应与 secu_params 解密（需真机扫码获得真实 token）。');
}
