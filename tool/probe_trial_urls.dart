import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'package:jxmusic/services/api/http.dart';

/// VIP/付费歌曲「试听版」探针 第六轮（酷狗最后一轮，手动运行）：
///   dart run tool/probe_trial_urls.dart
///
/// - songinfo / m3ws get_play_info：补全 web 端全量公共参数
///   （srcappid=2919 clientver clienttime uuid userid 等）+ 公开 salt 签名
Future<void> main() async {
  await probeKugouFull();
}

Future<void> probeKugouFull() async {
  print('========== 酷狗全参签名（匿名）==========');
  const hash = 'B3A52A7A958BF0AED0EBFBA2E9A818B7'; // 晴天（付费）
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final rng = Random.secure();
  final mid = List<String>.generate(
      32, (_) => '0123456789abcdef'[rng.nextInt(16)]).join();
  final uuid = List<String>.generate(
      32, (_) => '0123456789abcdef'[rng.nextInt(16)]).join();

  String sign(Map<String, String> params) {
    const salt = 'NVPh5oo716zF78tBBBfGgY3UvXPan9jm';
    final qs = (params.keys.toList()..sort())
        .map((k) => '$k=${Uri.encodeQueryComponent(params[k] ?? '')}')
        .join('&');
    return md5.convert(utf8.encode('$salt$qs$salt')).toString();
  }

  final common = <String, String>{
    'srcappid': '2919',
    'clientver': '11724',
    'clienttime': '$nowMs',
    'mid': mid,
    'uuid': uuid,
    'dfid': '-',
    'userid': '-1',
    'appid': '1014',
    'platid': '4',
    'album_id': '',
    'hash': hash,
    '_': '$nowMs',
  };

  // A) wwwapi songinfo（r 参与 / 不参与签名两组）
  for (final rInSign in [true, false]) {
    final params = {...common, 'r': 'play/getdata'};
    final signParams = rInSign ? params : (common..remove('r'));
    // 恢复 r（signParams 是 common 的引用时已被 remove）
    final qsMap = <String, String>{...common, 'r': 'play/getdata'};
    final sig = sign(rInSign ? qsMap : {...common});
    final qs = qsMap.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    try {
      final resp = await JXHttp.dio.get(
        'https://wwwapi.kugou.com/play/songinfo?$qs&signature=$sig',
        options: Options(headers: {
          'Referer': 'https://www.kugou.com/',
          'Cookie': 'kg_mid=$mid',
        }),
      );
      final root = resp.data is Map ? resp.data as Map : const {};
      final data = root['data'];
      final url = '${data is Map ? data['play_url'] ?? '' : ''}';
      print('  [songinfo r${rInSign ? '参与' : '不参与'}签名] status=${root['status']} '
          'err_code=${root['err_code']} play_url.len=${url.length}');
      if (url.isNotEmpty) {
        if (data is Map) {
          print('    timelength=${data['timelength']} filesize=${data['filesize']} '
              'is_free=${data['is_free']} privilege=${data['privilege']}');
        }
        await _downloadSample(jxUpgradeHttps(url), '    ↳ ');
      }
    } catch (e) {
      print('  [songinfo r${rInSign ? '参与' : '不参与'}签名] 异常: $e');
    }
  }

  // B) m3ws get_play_info
  {
    final params = <String, String>{...common, '_': '$nowMs'};
    final sig = sign(params);
    final qs = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    try {
      final resp = await JXHttp.dio.get(
        'https://m3ws.kugou.com/app/v2/get_play_info?$qs&signature=$sig',
        options: Options(headers: {
          'Referer': 'https://m3ws.kugou.com/',
          'Cookie': 'kg_mid=$mid',
        }),
      );
      print('  [m3ws get_play_info] 全量: ${jsonEncode(resp.data)}');
    } catch (e) {
      print('  [m3ws get_play_info] 异常: $e');
    }
  }
}

Future<void> _downloadSample(String url, String label) async {
  try {
    final dio = Dio();
    final resp = await dio.get<List<int>>(
      url,
      options: Options(
        headers: {'Range': 'bytes=0-65535'},
        responseType: ResponseType.bytes,
      ),
    );
    final bytes = resp.data ?? const <int>[];
    final head = bytes
        .take(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final total = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    print('${label}status=${resp.statusCode} got=${bytes.length}B 头4字节=$head '
        'Content-Range=$total');
  } catch (e) {
    print('${label}异常: $e');
  }
}
