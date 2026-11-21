// 临时探针：QQ uniform_get_Dissinfo 响应里的歌单元数据字段。
import 'dart:convert';

import 'package:dio/dio.dart';

Future<void> main() async {
  final dio = Dio(BaseOptions(
    validateStatus: (code) => code != null && code < 500,
    headers: {
      'Referer': 'https://y.qq.com/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    },
  ));
  final req = {
    'comm': {'ct': 24, 'cv': 0},
    'playlist': {
      'module': 'music.srfDissInfo.aiDissInfo',
      'method': 'uniform_get_Dissinfo',
      'param': {'disstid': 8276849972, 'userinfo': 1}
    }
  };
  final resp = await dio.get('https://u.y.qq.com/cgi-bin/musicu.fcg',
      queryParameters: {'format': 'json', 'data': jsonEncode(req)});
  dynamic body = resp.data;
  if (body is String) {
    try {
      body = jsonDecode(body);
    } catch (_) {}
  }
  dynamic data;
  if (body is Map) {
    final pl = body['playlist'];
    if (pl is Map) data = pl['data'];
  }
  print('status=${resp.statusCode}');
  if (data is Map) {
    print('data keys: ${data.keys.toList()}');
    for (final k in [
      'dissname', 'logo', 'dirinfo', 'total_song_num',
      'diss_cover', 'headurl', 'nickname'
    ]) {
      final v = data[k];
      if (v is Map || v is List) {
        print('  $k: ${jsonEncode(v).substring(0, jsonEncode(v).length > 200 ? 200 : jsonEncode(v).length)}');
      } else {
        print('  $k = $v');
      }
    }
  }
}
