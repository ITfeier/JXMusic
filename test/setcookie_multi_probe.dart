// ignore_for_file: avoid_print
// QA 独立探测（qing / 清朝·质量与安全）：验证「Set-Cookie 多值合并」的底层假设。
//
// 背景：阶段二 QQ 兑换链路声称支持「Set-Cookie 多值合并」（qq_api.dart:90-99
// _collectSetCookies 遍历 h['set-cookie']）。若 Dio/IO 适配器把多个 Set-Cookie
// 合并成一条逗号分隔字符串，则各 cookie 的解析会丢失（只能取到第一条），
// 将导致 check_sig 拿不到 p_skey。本探测用本地 HttpServer 返回 3 条 Set-Cookie，
// 断言 JXHttp.dio 收到的响应头仍是 3 个独立值，并按业务代码同样的方式解析。
//
// 用法：dart run test/setcookie_multi_probe.dart     （退出码 0 = 假设成立）
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:jxmusic/services/api/http.dart';

/// 与 lib/services/api/qq_api.dart:90-99 `_collectSetCookies` 相同的解析逻辑
/// （此处按 QA 视角独立复写，调用方传入 dio 的 Headers map）
Map<String, String> collect(Map<String, List<String>> headers) {
  final into = <String, String>{};
  final list = headers['set-cookie'];
  if (list == null) return into;
  for (final item in list) {
    final seg = item.split(';').first.trim();
    final eq = seg.indexOf('=');
    if (eq <= 0) continue;
    into[seg.substring(0, eq).trim()] = seg.substring(eq + 1).trim();
  }
  return into;
}

void main() async {
  var fails = 0;
  void check(String name, bool ok, String detail) {
    if (!ok) fails++;
    print('${ok ? '[PASS]' : '[FAIL]'} $name | $detail');
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    // check_sig 风格的响应：302 + 多条 Set-Cookie
    req.response.statusCode = 302;
    req.response.headers.add(HttpHeaders.setCookieHeader, 'p_skey=TEST_PSKEY; Path=/; Domain=graph.qq.com');
    req.response.headers.add(HttpHeaders.setCookieHeader, 'skey=TEST_SKEY; Path=/');
    req.response.headers.add(HttpHeaders.setCookieHeader, 'uin=o0123456789; Path=/');
    req.response.headers.add(HttpHeaders.locationHeader, 'https://graph.qq.com/oauth2.0/login_jump?code=abc');
    req.response.close();
  });

  try {
    final url = 'http://127.0.0.1:${server.port}/check_sig';
    final resp = await JXHttp.dio.get(
      url,
      options: Options(
        followRedirects: false,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final raw = resp.headers.map['set-cookie'];
    print('HTTP=${resp.statusCode}  set-cookie 原始条目数=${raw?.length}');
    for (var i = 0; i < (raw?.length ?? 0); i++) {
      print('  [$i] ${raw![i]}');
    }
    check('Dio 保留每条 Set-Cookie 为独立值（未被合并成一条）',
        (raw?.length ?? 0) == 3, '条目数=${raw?.length}');
    final cookies = collect(resp.headers.map);
    check('按业务解析逻辑能取到 p_skey', cookies['p_skey'] == 'TEST_PSKEY',
        'p_skey=${cookies['p_skey']}');
    check('按业务解析逻辑能合并全部 cookie', cookies.length == 3,
        '解析出=${cookies.keys.join(',')}');
  } finally {
    await server.close(force: true);
  }

  print(fails == 0
      ? '\n结果：PASS（Dio + IO 适配器保留 Set-Cookie 多值，qq_api 合并假设成立）'
      : '\n结果：FAIL（$fails 项不成立）');
  exitCode = fails == 0 ? 0 : 1;
}
