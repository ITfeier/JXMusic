// ignore_for_file: avoid_print, avoid_relative_lib_imports
// 临时探测脚本：验证酷狗官方 Web 扫码登录接口与 KuGouApi 实际实现。
// 依据：www.kugou.com 登录弹窗 popuplogin.v3.min.js + kguser.v2.min.js 的
//      KgUser.GetQRCode / GetQRCodeState。
// 用法：dart run tool/check_kg_qr_probe.dart
// 输出：取码 HTTP 状态、qrcode key、二维码内容（官方 PNG data-uri 长度/H5 URL）、
//      轮询返回的原始状态与 KuGouApi.pollQrLogin 的结果。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../lib/services/api/kugou_api.dart';

const salt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
const loginBase = 'https://login-user.kugou.com/';
const qrcodeH5 = 'https://h5.kugou.com/apps/loginQRCode/html/index.html';
const clientver = '8131';

String md5Hex(String s) => md5.convert(utf8.encode(s)).toString();

String randomHex32() {
  final r = Random.secure();
  return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
}

/// getInterFaceKguser 签名：MD5(salt + 按 key 排序的 "k=v" 直接拼接 + salt)
Map<String, String> sign(Map<String, String> input) {
  final p = Map<String, String>.of(input);
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  p['srcappid'] ??= '2919';
  if ((p['clientver'] ?? '').isEmpty) p['clientver'] = '20000';
  if ((p['clienttime'] ?? '').isEmpty) p['clienttime'] = '$nowMs';
  if ((p['mid'] ?? '').isEmpty) p['mid'] = '$nowMs';
  if ((p['uuid'] ?? '').isEmpty) p['uuid'] = '$nowMs';
  if ((p['dfid'] ?? '').isEmpty) p['dfid'] = '-';
  final keys = p.keys.toList()..sort();
  final joined = keys.map((k) => '$k=${p[k]}').join();
  p['signature'] = md5Hex('$salt$joined$salt').toUpperCase();
  return p;
}

final dio = Dio(BaseOptions(
  headers: {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://login-user.kugou.com/login/?appid=1014',
    'Accept': 'application/json, text/javascript, */*; q=0.01',
  },
  responseType: ResponseType.plain,
  validateStatus: (_) => true,
  connectTimeout: const Duration(seconds: 15),
  receiveTimeout: const Duration(seconds: 20),
));

/// 直接按官方 Web 协议请求（不含业务封装），作为接口层证据
Future<String?> rawProtocolProbe() async {
  print('========== [A] 原始接口探测（官方 Web 协议）==========');
  final mid = randomHex32();
  final create = sign({
    'appid': '1014',
    'clientver': clientver,
    'clienttime': '${DateTime.now().millisecondsSinceEpoch}',
    'mid': mid,
    'uuid': mid,
    'dfid': '-',
    'type': '1',
    'plat': '4',
    'qrcode_txt': '$qrcodeH5?appid=1014&',
  });
  final r1 = await dio.get('${loginBase}v2/qrcode', queryParameters: create);
  print('[create] GET ${loginBase}v2/qrcode');
  print('[create] HTTP ${r1.statusCode}');
  print('[create] body: ${r1.data}');
  if (r1.statusCode != 200) return null;
  final j1 = jsonDecode('${r1.data}') as Map<String, dynamic>;
  final key = j1['data']?['qrcode'] as String?;
  final img = j1['data']?['qrcode_img'] as String?;
  print('--- key = "$key" (len=${key?.length})');
  print('--- qrcode_img = ${img == null ? 'null' : 'data-uri len=${img.length}'}');
  print('--- 二维码内容(H5) = $qrcodeH5?appid=1014&qrcode=$key');
  if (key == null || key.isEmpty) return null;

  for (var i = 1; i <= 3; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final poll = sign({
      'appid': '1014',
      'clientver': clientver,
      'clienttime': '${DateTime.now().millisecondsSinceEpoch}',
      'mid': mid,
      'uuid': mid,
      'dfid': '-',
      'plat': '4',
      'qrcode': key,
    });
    final r = await dio.get('${loginBase}v2/get_userinfo_qrcode',
        queryParameters: poll);
    print('[poll$i] HTTP ${r.statusCode} body: ${r.data}');
  }
  return key;
}

/// 通过真实业务类 KuGouApi 调用，验证修复后代码（含 JXHttp 公共 header）
Future<void> apiProbe() async {
  print('========== [B] KuGouApi 实现探测 ==========');
  final api = KuGouApi();
  final t0 = DateTime.now();
  final created = await api.createQrLogin();
  final cost = DateTime.now().difference(t0).inMilliseconds;
  print('[createQrLogin] cost=${cost}ms key="${created.key}" '
      '(len=${created.key.length})');
  print('[createQrLogin] qrUrl prefix=${created.qrUrl.length > 60 ? created.qrUrl.substring(0, 60) : created.qrUrl}...');
  print('[createQrLogin] qrUrl total len=${created.qrUrl.length}');
  if (created.qrUrl.startsWith('data:image/')) {
    final comma = created.qrUrl.indexOf(',');
    final bytes = base64Decode(created.qrUrl.substring(comma + 1));
    final isPng = bytes.length > 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
    print('[createQrLogin] PNG bytes=${bytes.length} isPng=$isPng '
        '(UI: Image.memory 渲染, 无需联网)');
  } else {
    print('[createQrLogin] 非 data-uri，按文本二维码渲染: ${created.qrUrl}');
  }
  if (created.key.isEmpty) {
    print('!! createQrLogin 失败');
    return;
  }
  for (var i = 1; i <= 3; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final s = await api.pollQrLogin(created.key);
    print('[pollQrLogin$i] => ${s == null ? 'null(等待中)' : 'session: ${s.nickname} cookies=${s.cookies}'}');
  }
  print('--- 预期：轮询均返回 null（未扫码），不抛异常');
}

Future<void> main(List<String> args) async {
  await rawProtocolProbe();
  await apiProbe();
  if (args.contains('--save')) {
    final api = KuGouApi();
    final created = await api.createQrLogin();
    final comma = created.qrUrl.indexOf(',');
    if (created.qrUrl.startsWith('data:image/') && comma > 0) {
      final bytes = base64Decode(created.qrUrl.substring(comma + 1));
      final path = '${Directory.systemTemp.path}\\kg_qr_sample.png';
      await File(path).writeAsBytes(bytes);
      print('[save] 二维码 PNG 已保存: $path (bytes=${bytes.length})');
    }
  }
}
