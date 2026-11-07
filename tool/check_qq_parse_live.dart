import 'package:dio/dio.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// QQ 扫码轮询解析的实网检查（手动运行）：
///   dart run tool/check_qq_parse_live.dart
///
/// 验证两件事：
/// 1) 容错解析器能正确识别真实 `ptuiCB(...)` 响应（含最后一项前带空格的情况）；
/// 2) 真实 QQMusicApi.pollQrLogin 在未扫码时返回 null 且 lastError 为空
///    （不再误报"轮询返回异常内容"）。
Future<void> main() async {
  const appid = '716027609';
  const daid = '383';
  const pt3rdAid = '100497308';
  const loginJump = 'https://graph.qq.com/oauth2.0/login_jump';
  const referer = 'https://xui.ptlogin2.qq.com/';
  const ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36';

  int hash33(String s) {
    var e = 0;
    for (final c in s.codeUnits) {
      e += (e << 5) + c;
    }
    return 2147483647 & e;
  }

  var failed = false;
  print('=== 1) 原始取码 + 轮询，检查真实 ptuiCB 格式 ===');
  try {
    final show = await JXHttp.dio.get(
      'https://ssl.ptlogin2.qq.com/ptqrshow',
      queryParameters: {
        'appid': appid,
        'e': '2',
        'l': 'M',
        's': '3',
        'd': '72',
        'v': '4',
        't': '${DateTime.now().millisecondsSinceEpoch}',
        'daid': daid,
        'pt_3rd_aid': pt3rdAid,
      },
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'User-Agent': ua, 'Referer': referer},
      ),
    );
    final setCookie = show.headers.map['set-cookie'] ?? const <String>[];
    var qrsig = '';
    for (final c in setCookie) {
      final m = RegExp(r'qrsig=([^;]+)').firstMatch(c);
      if (m != null) qrsig = m.group(1)!;
    }
    if (qrsig.isEmpty) {
      print('  [FAIL] 未取到 qrsig');
      failed = true;
    } else {
      print('  取码 OK qrsig=${qrsig.length} 字符');
      final poll = await JXHttp.dio.get(
        'https://ssl.ptlogin2.qq.com/ptqrlogin',
        queryParameters: {
          'u1': loginJump,
          'ptqrtoken': '${hash33(qrsig)}',
          'ptredirect': '0',
          'h': '1',
          't': '1',
          'g': '1',
          'from_ui': '1',
          'ptlang': '2052',
          'action': '0-0-${DateTime.now().millisecondsSinceEpoch}',
          'js_ver': '20102616',
          'js_type': '1',
          'pt_uistyle': '40',
          'aid': appid,
          'daid': daid,
          'pt_3rd_aid': pt3rdAid,
          'has_onekey': '1',
        },
        options: Options(headers: {
          'User-Agent': ua,
          'Referer': referer,
          'Cookie': 'qrsig=$qrsig',
        }),
      );
      final text = '${poll.data}';
      print('  轮询原文: $text');
      final cb = parsePtuiCb(text);
      print('  解析结果: ${cb == null ? 'null' : "code=${cb.code}"}');
      if (cb == null || (cb.code != '66' && cb.code != '67')) {
        print('  [FAIL] 解析未得到等待态');
        failed = true;
      }
    }
  } catch (e) {
    print('  [FAIL] 请求异常: $e');
    failed = true;
  }

  print('');
  print('=== 2) 真实 QQMusicApi：取码 + 轮询（lastError 应为空）===');
  try {
    final api = QQMusicApi();
    final created = await api.createQrLogin();
    print('  createQrLogin: qrUrl.len=${created.qrUrl.length} key.len=${created.key.length}');
    if (created.key.isEmpty) {
      print('  [FAIL] 取码失败 ${api.lastError}');
      failed = true;
    } else {
      final session = await api.pollQrLogin(created.key);
      print('  pollQrLogin: ${session == null ? 'null(等待中)' : 'session'}');
      print('  lastError: ${api.lastError ?? '(空)'}');
      if (session != null || (api.lastError != null && api.lastError!.isNotEmpty)) {
        print('  [FAIL] 未扫码时不应有 session，也不应误报错误');
        failed = true;
      }
    }
  } catch (e) {
    print('  [FAIL] API 异常: $e');
    failed = true;
  }

  print('');
  print(failed ? '结果：FAIL' : '结果：PASS（解析容错生效，等待态不再误报错）');
}
