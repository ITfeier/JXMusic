// 网易云扫码登录链路探测脚本（联网，手动运行，可复现本轮修复的证据）：
//   dart run tool/check_netease_qr.dart
//
// 输出三段证据：
//   1) NeteaseApi.createQrLogin()：取码是否成功、unikey 打码结构、lastError
//   2) NeteaseApi.pollQrLogin()：未扫码时应为等待态（返回 null、lastError 为 null）
//   3) 原始 /api/login/qrcode/client/login 响应：证明端点可达、code 语义（801 等待）
//
// 2026-11-09 本机实测输出（见 docs/projects/扫码登录修复/修复报告-实扫.md）：
//   [create] key=40bb…(len=36) lastError=-
//   [poll1..3] session=null(等待) lastError=-
//   [raw] HTTP=200 body={"code":801,"message":"等待扫码"} ...
// 退出码 0 = 取码成功 + 轮询处于等待态 + endpoint 可达。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/netease_api.dart';

String mask(String value, {int keep = 4}) {
  if (value.isEmpty) return '(空)';
  if (value.length <= keep * 2) return 'len=${value.length}';
  return '${value.substring(0, keep)}…(len=${value.length})';
}

Future<void> main() async {
  var failed = false;
  final api = NeteaseApi();

  print('=== 1) NeteaseApi.createQrLogin() ===');
  final created = await api.createQrLogin();
  final qrShown = created.qrUrl.isEmpty
      ? '空'
      : created.qrUrl.replaceAll(RegExp(r'codekey=.*'), 'codekey=${mask(created.key)}');
  print('[create] qrUrl=$qrShown key=${mask(created.key)} '
      'lastError=${api.lastError ?? '-'}');
  if (created.qrUrl.isEmpty || created.key.isEmpty) {
    failed = true;
  }

  if (created.key.isNotEmpty) {
    print('');
    print('=== 2) NeteaseApi.pollQrLogin()（无人扫码，应保持等待态）===');
    for (var i = 1; i <= 3; i++) {
      final session = await api.pollQrLogin(created.key);
      print('[poll$i] session=${session == null ? 'null(等待)' : session.nickname} '
          'lastError=${api.lastError ?? '-'}');
      if (session != null) failed = true; // 本轮无人扫码，出现 session 反而不正常
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  print('');
  print('=== 3) 原始 client/login 响应（证明端点可达与 code 语义）===');
  try {
    final resp = await JXHttp.dio.post(
        'https://music.163.com/api/login/qrcode/client/login',
        data: {'key': created.key.isEmpty ? 'probe-invalid-key' : created.key, 'type': 1},
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          receiveTimeout: const Duration(seconds: 10),
        ));
    final cookieNames = (resp.headers['set-cookie'] ?? const <String>[])
        .map((e) => e.split(';').first.split('=').first)
        .join(',');
    print('[raw] HTTP=${resp.statusCode} body=${jsonEncode(resp.data)} '
        'set-cookie-names=[$cookieNames]');
    final code = resp.data is Map ? resp.data['code'] : null;
    if ('$code' != '801') failed = true;
  } catch (e) {
    failed = true;
    print('[raw] 异常：$e');
  }

  print('');
  print(failed
      ? '结果：FAIL（见上方输出）'
      : '结果：PASS（取码成功、轮询为 801 等待态、client/login 端点可达）');
  exitCode = failed ? 1 : 0;
}
