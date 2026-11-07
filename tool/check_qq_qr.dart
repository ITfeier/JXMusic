// QQ 音乐扫码登录链路探测脚本（手动运行，可复现验收证据）：
//   dart run tool/check_qq_qr.dart
//
// 输出四段证据：
//   1) 原始 ptqrshow 取码：HTTP 状态、PNG 字节数/尺寸、qrsig 长度
//   2) 原始 ptqrlogin 轮询：HTTP 状态、ptuiCB code（未扫码应为 66 等待态）
//   3) 走真实 QQMusicApi 实现：createQrLogin() / pollQrLogin() 行为
//   4) 扫码后兑换链路候选端点可达性（假参数，证明端点/风控状态，不证明业务成功）
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/qq_api.dart';

const _appid = '716027609';
const _daid = '383';
const _pt3rdAid = '100497308';
const _referer = 'https://xui.ptlogin2.qq.com/';
const _loginJump = 'https://graph.qq.com/oauth2.0/login_jump';

int hash33(String s, [int h = 0]) {
  var e = h;
  for (final c in s.codeUnits) {
    e += (e << 5) + c;
  }
  return 2147483647 & e;
}

String pngSize(List<int> b) {
  if (b.length < 24) return '?';
  final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
  final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
  return '${w}x$h';
}

String head(List<int> b, int n) =>
    b.take(n).map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  var failed = false;

  print('=== 1) 原始 ptqrshow 取码 ===');
  List<int> png = const [];
  var qrsig = '';
  try {
    final show = await JXHttp.dio.get('https://ssl.ptlogin2.qq.com/ptqrshow',
        queryParameters: {
          'appid': _appid,
          'e': '2',
          'l': 'M',
          's': '3',
          'd': '72',
          'v': '4',
          't': DateTime.now().millisecondsSinceEpoch.toString(),
          'daid': _daid,
          'pt_3rd_aid': _pt3rdAid,
        },
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Referer': _referer},
        ));
    png = (show.data as List<int>?) ?? const [];
    final setCookie = (show.headers['set-cookie'] ?? const <String>[]).join(' ; ');
    qrsig = RegExp(r'qrsig=([^;]+)').firstMatch(setCookie)?.group(1) ?? '';
    print('HTTP=${show.statusCode}  PNG字节=${png.length}  尺寸=${pngSize(png)}  '
        '魔数=${head(png, 4)}  qrsig长度=${qrsig.length}');
    if (show.statusCode != 200 || png.length < 100 || qrsig.length <= 40) {
      failed = true;
    }
  } catch (e) {
    failed = true;
    print('取码异常：$e');
  }

  print('');
  print('=== 2) 原始 ptqrlogin 轮询（未扫码应为 code 66）===');
  try {
    final resp = await JXHttp.dio.get('https://ssl.ptlogin2.qq.com/ptqrlogin',
        queryParameters: {
          'u1': _loginJump,
          'ptqrtoken': hash33(qrsig).toString(),
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
          'aid': _appid,
          'daid': _daid,
          'pt_3rd_aid': _pt3rdAid,
          'has_onekey': '1',
        },
        options: Options(headers: {
          'Referer': _referer,
          'Cookie': 'qrsig=$qrsig',
        }));
    final text = '${resp.data}';
    print('HTTP=${resp.statusCode}  响应=${text}');
    final code = RegExp(r"ptuiCB\('(\d+)'").firstMatch(text)?.group(1) ?? '';
    print('ptuiCB code=$code  '
        '${code == '66' || code == '67' ? '(等待态，符合预期)' : '(非等待态)'}');
    if (resp.statusCode != 200 || (code != '66' && code != '67')) failed = true;
  } catch (e) {
    failed = true;
    print('轮询异常：$e');
  }

  print('');
  print('=== 3) 真实 QQMusicApi 实现 ===');
  final api = QQMusicApi();
  final created = await api.createQrLogin();
  if (created.qrUrl.isEmpty || created.key.isEmpty) {
    failed = true;
    print('createQrLogin() => 空结果（取码失败）');
  } else {
    final prefix = created.qrUrl.substring(0, 40);
    final b64 = created.qrUrl.substring(created.qrUrl.indexOf(',') + 1);
    final decoded = base64Decode(b64);
    print('createQrLogin(): qrUrl 前缀=$prefix...  '
        'base64 解码后 PNG 字节=${decoded.length}  尺寸=${pngSize(decoded)}');
    print('                  key(qrsig)长度=${created.key.length}');
    final out = Platform.environment['QQ_QR_OUT'];
    if (out != null && out.isNotEmpty) {
      // 可选：把二维码 PNG 落盘，便于目视确认是真二维码（不写进仓库）
      File(out).writeAsBytesSync(decoded);
      print('                  二维码 PNG 已保存：$out');
    }
    if (decoded.length < 100) failed = true;
    final session = await api.pollQrLogin(created.key);
    print('pollQrLogin() => ${session == null ? 'null（等待扫码，符合预期）' : 'session: ${session.nickname}'}');
  }

  print('');
  print('=== 4) 兑换链路候选端点可达性（假参数，仅证明端点/风控，不证明业务成功）===');
  try {
    final sig = await JXHttp.dio.get(
        'https://ssl.ptlogin2.graph.qq.com/check_sig',
        queryParameters: {
          'uin': 'o0123456789',
          'pttype': '1',
          'service': 'ptqrlogin',
          'nodirect': '0',
          'ptsigx': 'FAKE_SIGX_PROBE',
          's_url': _loginJump,
          'ptlang': '2052',
          'ptredirect': '100',
          'aid': _appid,
          'daid': _daid,
          'j_later': '0',
          'low_login_hour': '0',
          'regmaster': '0',
          'pt_login_type': '3',
          'pt_aid': '0',
          'pt_aaid': '16',
          'pt_light': '0',
          'pt_3rd_aid': _pt3rdAid,
        },
        options: Options(
          followRedirects: false,
          validateStatus: (s) => s != null && s < 500,
          headers: {'Referer': _referer},
        ));
    print('check_sig  : HTTP=${sig.statusCode}  '
        'location=${_cut(sig.headers.value('location') ?? '-')}');
  } catch (e) {
    print('check_sig 异常：$e');
  }

  try {
    final auth = await JXHttp.dio.post(
        'https://graph.qq.com/oauth2.0/authorize',
        data: {
          'response_type': 'code',
          'client_id': _pt3rdAid,
          'redirect_uri':
              'https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/',
          'state': 'state',
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: false,
          validateStatus: (s) => s != null && s < 500,
          headers: {
            'Referer': 'https://graph.qq.com/',
            'Cookie': 'p_skey=FAKE_PROBE',
          },
        ));
    print('authorize  : HTTP=${auth.statusCode}  '
        'location=${_cut(auth.headers.value('location') ?? '-')}');
  } catch (e) {
    print('authorize 异常：$e');
  }

  final qqLoginPayload = jsonEncode({
    'comm': {
      'ct': 24,
      'cv': 4747474,
      'platform': 'yqq.json',
      'format': 'json',
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
      'notice': 0,
      'need_new_code': 1,
      'tmeLoginType': 2,
    },
    'req': {
      'module': 'QQConnectLogin.LoginServer',
      'method': 'QQLogin',
      'param': {'code': 'fake'},
    },
  });
  for (final base in const [
    'https://u.y.qq.com/cgi-bin/musicu.fcg',
    'https://u6.y.qq.com/cgi-bin/musicu.fcg',
    'https://u.y.qq.com/cgi-bin/musics.fcg',
  ]) {
    try {
      final r = await JXHttp.dio.get(base,
          queryParameters: {'format': 'json', 'data': qqLoginPayload},
          options: Options(headers: {'Referer': 'https://y.qq.com/'}));
      final raw = r.data;
      final outer = raw is Map ? raw['code'] : '-';
      final req = raw is Map ? (raw['req'] ?? raw['req_0']) : null;
      final biz = req is Map ? req['code'] : '-';
      print('QQLogin    : $base -> HTTP=${r.statusCode} '
          '外层code=$outer 业务code=$biz');
    } catch (e) {
      print('QQLogin    : $base 异常：$e');
    }
  }
  print('（假 code=fake：主/备1 返回业务 code=1000 属预期；'
      '备2 musics.fcg 需 zzc sign，返回 2000）');
  print('（真机扫码后的 check_sig→authorize→QQLogin 全链路未端到端验证）');

  print('');
  print(failed ? '结果：FAIL（见上方标红项）' : '结果：PASS（取码为真二维码，轮询处于等待态）');
  exitCode = failed ? 1 : 0;
}

/// 截断长 URL/字符串，便于输出对照
String _cut(String s, [int n = 120]) => s.length <= n ? s : s.substring(0, n);
