// ignore_for_file: avoid_print
// QA 独立探测（qing / 清朝·质量与安全）：
//   dart run test/qr_http_probe.dart
//
// 与开发者的 tool/check_*.dart 相互独立：
//   * 不 import 任何 lib/ 业务代码（不经过 JXHttp / QQMusicApi / KuGouApi），
//     直接按平台官方 Web 协议用 dart:io HttpClient 发原始 HTTP 请求；
//   * 签名/参数算法在脚本内独立实现（crypto 只用于 MD5）；
//   * 逐项断言验收口径，输出 [PASS]/[FAIL]，失败时退出码 1。
//
// 覆盖：
//   QQ  A. ptqrshow 取码：HTTP 200 + PNG 魔数 + 二维码尺寸 + qrsig > 40
//       B. ptqrlogin 轮询：HTTP 200 + ptuiCB code 66/67（等待态）
//       C. 反例：带 u1 的旧取码参数应被拒（验证代码注释里的 403 结论）
//   酷狗 A. v2/qrcode 取码：HTTP 200 + status=1 + qrcode key 非空 + 官方 PNG data-uri
//       B. v2/get_userinfo_qrcode 轮询：HTTP 200 + data.status=1（等待态）
//
// 二维码 PNG 会落盘到系统临时目录，便于 read_image 目视确认真二维码。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

// ---------- 通用 ----------
const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0 Safari/537.36';

int _failures = 0;

void check(String name, bool ok, String detail) {
  if (!ok) _failures++;
  print('${ok ? '[PASS]' : '[FAIL]'} $name | $detail');
}

String _hex(List<int> b) =>
    b.take(8).map((x) => x.toRadixString(16).padLeft(2, '0')).join();

bool _isPng(List<int> b) =>
    b.length >= 33 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;

String _pngSize(List<int> b) {
  if (b.length < 24) return '?';
  final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
  final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
  return '${w}x$h';
}

class HttpResult {
  final int status;
  final Map<String, List<String>> headers;
  final List<int> body;
  const HttpResult(this.status, this.headers, this.body);

  String get text => utf8.decode(body, allowMalformed: true);
  String get setCookie => (headers['set-cookie'] ?? const <String>[]).join(' ; ');
}

Future<HttpResult> getRaw(String url,
    {Map<String, String> headers = const {}, bool followRedirects = true}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.followRedirects = followRedirects;
    req.headers.set('User-Agent', _ua);
    headers.forEach(req.headers.set);
    final resp = await req.close();
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
    }
    final respHeaders = <String, List<String>>{};
    resp.headers.forEach(
        (name, values) => respHeaders[name.toLowerCase()] = values);
    return HttpResult(resp.statusCode, respHeaders, bytes);
  } finally {
    client.close(force: true);
  }
}

Uri _uri(String base, Map<String, String> params) {
  final u = Uri.parse(base);
  return u.replace(queryParameters: {...u.queryParameters, ...params});
}

// ---------- QQ ----------
const String _qqAppid = '716027609';
const String _qqDaid = '383';
const String _qq3rdAid = '100497308';
const String _qqLoginJump = 'https://graph.qq.com/oauth2.0/login_jump';
const String _qqReferer = 'https://xui.ptlogin2.qq.com/';

int _hash33(String s, [int h = 0]) {
  var e = h;
  for (final c in s.codeUnits) {
    e += (e << 5) + c;
  }
  return 2147483647 & e;
}

Future<void> probeQq() async {
  print('\n===== QQ：ptqrshow 取码 + ptqrlogin 轮询 =====');
  final show = await getRaw(_uri(
      'https://ssl.ptlogin2.qq.com/ptqrshow',
      {
        'appid': _qqAppid,
        'e': '2',
        'l': 'M',
        's': '3',
        'd': '72',
        'v': '4',
        't': '${DateTime.now().millisecondsSinceEpoch}',
        'daid': _qqDaid,
        'pt_3rd_aid': _qq3rdAid,
      }).toString(),
      headers: {'Referer': _qqReferer});

  final png = show.body;
  final qrsig = RegExp(r'qrsig=([^;]+)').firstMatch(show.setCookie)?.group(1) ?? '';
  check('QQ-A1 ptqrshow HTTP 200', show.status == 200, 'HTTP=${show.status}');
  check('QQ-A2 响应为 PNG（魔数 89504e47）', _isPng(png),
      'len=${png.length} 魔数=${_hex(png)} 尺寸=${_pngSize(png)}');
  check('QQ-A3 二维码尺寸 >= 80x80', () {
    if (png.length < 24) return false;
    final w = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
    final h = (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23];
    return w >= 80 && h >= 80;
  }(), '尺寸=${_pngSize(png)}（真二维码应为 111x111；占位图不符合）');
  check('QQ-A4 qrsig 长度 > 40', qrsig.length > 40, 'qrsig长度=${qrsig.length}');
  final dir = Directory('${Directory.systemTemp.path}/jxmusic_qa_evidence')
    ..createSync(recursive: true);
  final pngPath = '${dir.path}/qq_ptqrshow.png';
  File(pngPath).writeAsBytesSync(png);
  print('[INFO] QQ 二维码 PNG 已保存：$pngPath');

  if (qrsig.isEmpty) {
    print('[SKIP] 无 qrsig，跳过轮询');
    return;
  }

  // QQ-A5：连续两次取码必须是不同图片（真二维码随 qrsig 变化；静态占位图会逐字节相同）
  final show2 = await getRaw(_uri(
      'https://ssl.ptlogin2.qq.com/ptqrshow',
      {
        'appid': _qqAppid,
        'e': '2',
        'l': 'M',
        's': '3',
        'd': '72',
        'v': '4',
        't': '${DateTime.now().millisecondsSinceEpoch}',
        'daid': _qqDaid,
        'pt_3rd_aid': _qq3rdAid,
      }).toString(),
      headers: {'Referer': _qqReferer});
  final qrsig2 =
      RegExp(r'qrsig=([^;]+)').firstMatch(show2.setCookie)?.group(1) ?? '';
  final sameBytes = png.length == show2.body.length &&
      List.generate(png.length, (i) => png[i] == show2.body[i])
          .every((x) => x);
  File('${dir.path}/qq_ptqrshow_2.png').writeAsBytesSync(show2.body);
  check('QQ-A5 连续两次取码为不同二维码（非静态占位图）',
      !sameBytes && qrsig2.isNotEmpty && qrsig2 != qrsig,
      'img1=${png.length}B sha差异=${!sameBytes} qrsig1=${qrsig.length}字符 '
      'qrsig2=${qrsig2.length}字符 相同=$sameBytes');
  final poll = await getRaw(_uri(
      'https://ssl.ptlogin2.qq.com/ptqrlogin',
      {
        'u1': _qqLoginJump,
        'ptqrtoken': '${_hash33(qrsig)}',
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
        'aid': _qqAppid,
        'daid': _qqDaid,
        'pt_3rd_aid': _qq3rdAid,
        'has_onekey': '1',
      }).toString(),
      headers: {'Referer': _qqReferer, 'Cookie': 'qrsig=$qrsig'});
  final code =
      RegExp(r"ptuiCB\('(\d+)'").firstMatch(poll.text)?.group(1) ?? '';
  check('QQ-B1 ptqrlogin HTTP 200', poll.status == 200, 'HTTP=${poll.status}');
  check('QQ-B2 未扫码返回等待态 code 66/67', code == '66' || code == '67',
      'ptuiCB code=$code 响应=${poll.text.trim()}');

  // 反例 1：旧实现带 u1 的请求应被网关拒绝，印证代码注释中「带 u1 会 403」的结论
  final oldWithU1 = await getRaw(
      _uri('https://ssl.ptlogin2.qq.com/ptqrshow', {
        'appid': _qqAppid,
        'e': '2',
        'l': 'M',
        's': '3',
        'd': '72',
        'v': '4',
        't': '${DateTime.now().millisecondsSinceEpoch}',
        'daid': _qqDaid,
        'pt_3rd_aid': _qq3rdAid,
        'u1': 'https://y.qq.com/portal/wxa_redirect.html?login_type=1',
      }).toString(),
      headers: {'Referer': _qqReferer});
  print('[INFO] QQ-C 反例1（带 u1 旧参数）HTTP=${oldWithU1.status} '
      '${oldWithU1.status == 200 ? '（本次未被拒，可能网关策略变化；主链路仍以 A/B 为准）' : '（符合代码注释：被拒）'}');

  // 反例 2：更旧实现（去掉 daid/pt_3rd_aid，也不带 u1）——开发者称返回 200 但是占位图。
  // 对照：与 A 的图片逐字节不同 + 尺寸是否仍为 111x111，用来证明「尺寸/字节数不能单独判真伪」。
  final oldNoDaid = await getRaw(
      _uri('https://ssl.ptlogin2.qq.com/ptqrshow', {
        'appid': _qqAppid,
        'e': '2',
        'l': 'M',
        's': '3',
        'd': '72',
        'v': '4',
        't': '${DateTime.now().millisecondsSinceEpoch}',
      }).toString(),
      headers: {'Referer': _qqReferer});
  final noDaidIsPng = _isPng(oldNoDaid.body);
  final sameAsFirst = oldNoDaid.body.length == png.length &&
      List.generate(png.length, (i) => png[i] == oldNoDaid.body[i])
          .every((x) => x);
  File('${dir.path}/qq_ptqrshow_no_daid.png')
      .writeAsBytesSync(oldNoDaid.body);
  print('[INFO] QQ-D 反例2（去掉 daid/pt_3rd_aid，旧实现）HTTP=${oldNoDaid.status} '
      '字节=${oldNoDaid.body.length} PNG=$noDaidIsPng 尺寸=${_pngSize(oldNoDaid.body)} '
      '与A相同=$sameAsFirst（说明：尺寸/字节数几乎一样，不能靠大小判真伪）');
}

// ---------- 酷狗 ----------
const String _kgSalt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
const String _kgLoginBase = 'https://login-user.kugou.com/';
const String _kgReferer = 'https://login-user.kugou.com/login/?appid=1014';
const String _kgH5 =
    'https://h5.kugou.com/apps/loginQRCode/html/index.html';

String _randomHex32() {
  final r = RandomSeed();
  return r.hex32();
}

/// 简单可复现的 32 位小写十六进制（不依赖 Random.secure，避免脚本环境限制）
class RandomSeed {
  int _s = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
  int _next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s;
  }

  String hex32() {
    final sb = StringBuffer();
    while (sb.length < 32) {
      sb.write(_next().toRadixString(16).padLeft(8, '0'));
    }
    return sb.toString().substring(0, 32);
  }
}

/// 官方 getInterFaceKguser 签名：
/// MD5(salt + 按 key 升序拼接 "k=v"（无分隔符） + salt)，大写。
Map<String, String> _kgSign(Map<String, String> input) {
  final p = Map<String, String>.of(input);
  final now = '${DateTime.now().millisecondsSinceEpoch}';
  p['srcappid'] ??= '2919';
  if ((p['clientver'] ?? '').isEmpty) p['clientver'] = '20000';
  if ((p['clienttime'] ?? '').isEmpty) p['clienttime'] = now;
  if ((p['mid'] ?? '').isEmpty) p['mid'] = now;
  if ((p['uuid'] ?? '').isEmpty) p['uuid'] = now;
  if ((p['dfid'] ?? '').isEmpty) p['dfid'] = '-';
  final keys = p.keys.toList()..sort();
  final joined = keys.map((k) => '$k=${p[k]}').join();
  p['signature'] =
      md5.convert(utf8.encode('$_kgSalt$joined$_kgSalt')).toString().toUpperCase();
  return p;
}

Future<void> probeKugou() async {
  print('\n===== 酷狗：v2/qrcode 取码 + v2/get_userinfo_qrcode 轮询 =====');
  final mid = _randomHex32();
  final create = _kgSign({
    'appid': '1014',
    'clientver': '8131',
    'clienttime': '${DateTime.now().millisecondsSinceEpoch}',
    'mid': mid,
    'uuid': mid,
    'dfid': '-',
    'type': '1',
    'plat': '4',
    'qrcode_txt': '$_kgH5?appid=1014&',
  });
  final sig = create['signature'] ?? '';
  check('KG-A0 签名格式（32 位大写十六进制）',
      RegExp(r'^[0-9A-F]{32}$').hasMatch(sig), 'signature=$sig');

  final r1 =
      await getRaw(_uri('${_kgLoginBase}v2/qrcode', create).toString(),
          headers: {'Referer': _kgReferer});
  Map<String, dynamic>? j1;
  try {
    j1 = jsonDecode(r1.text) as Map<String, dynamic>;
  } catch (_) {}
  final data1 = j1?['data'];
  final key = (data1 is Map ? '${data1['qrcode'] ?? ''}' : '');
  final img = (data1 is Map ? '${data1['qrcode_img'] ?? ''}' : '');
  check('KG-A1 qrcode HTTP 200', r1.status == 200, 'HTTP=${r1.status}');
  check('KG-A2 顶层 status=1 且 error_code=0',
      j1?['status'] == 1 && j1?['error_code'] == 0,
      'status=${j1?['status']} error_code=${j1?['error_code']}');
  check('KG-A3 qrcode key 非空', key.isNotEmpty, 'key=$key (len=${key.length})');
  var pngOk = false;
  var pngLen = 0;
  if (img.startsWith('data:image/png;base64,')) {
    final bytes = base64Decode(img.substring(img.indexOf(',') + 1));
    pngLen = bytes.length;
    pngOk = _isPng(bytes);
    final path =
        '${Directory.systemTemp.path}/jxmusic_qa_evidence/kg_qrcode_img.png';
    File(path).writeAsBytesSync(bytes);
    print('[INFO] 酷狗官方二维码 PNG 已保存：$path');
  }
  check('KG-A4 官方 qrcode_img 为 PNG data-uri 且魔数正确', pngOk,
      'img长度=${img.length} 解码后=$pngLen 字节');

  if (key.isEmpty) {
    print('[SKIP] 无 key，跳过轮询');
    return;
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  final pollParams = _kgSign({
    'appid': '1014',
    'clientver': '8131',
    'clienttime': '${DateTime.now().millisecondsSinceEpoch}',
    'mid': mid,
    'uuid': mid,
    'dfid': '-',
    'plat': '4',
    'qrcode': key,
  });
  final r2 = await getRaw(
      _uri('${_kgLoginBase}v2/get_userinfo_qrcode', pollParams).toString(),
      headers: {'Referer': _kgReferer});
  Map<String, dynamic>? j2;
  try {
    j2 = jsonDecode(r2.text) as Map<String, dynamic>;
  } catch (_) {}
  final d2 = j2?['data'];
  final status = d2 is Map ? d2['status'] : null;
  check('KG-B1 get_userinfo_qrcode HTTP 200', r2.status == 200,
      'HTTP=${r2.status}');
  check('KG-B2 顶层 status=1', j2?['status'] == 1,
      'status=${j2?['status']} error_code=${j2?['error_code']}');
  check('KG-B3 未扫码返回等待态 data.status=1', status == 1,
      'data.status=$status');
}

Future<void> main() async {
  print('QA 独立探测：dart:io 原始 HTTP（不经过 lib/ 与 dio）');
  print('时间：${DateTime.now().toIso8601String()}');
  try {
    await probeQq();
  } catch (e, st) {
    _failures++;
    print('[FAIL] QQ 探测异常：$e\n$st');
  }
  try {
    await probeKugou();
  } catch (e, st) {
    _failures++;
    print('[FAIL] 酷狗探测异常：$e\n$st');
  }
  print('\n结果：${_failures == 0 ? 'PASS（全部断言通过）' : 'FAIL（$_failures 项未通过）'}');
  exitCode = _failures == 0 ? 0 : 1;
}
