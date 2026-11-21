// 临时探针：看 QQ GetPlaylistByUin 返回的歌单元素里封面字段到底叫什么。
import 'dart:convert';

import 'package:dio/dio.dart';

Future<void> main() async {
  final dio = Dio(BaseOptions(
    responseType: ResponseType.json,
    validateStatus: (code) => code != null && code < 500,
  ));
  final resp = await dio.post(
    'https://u.y.qq.com/cgi-bin/musicu.fcg',
    data: jsonEncode({
      'comm': {'ct': 24, 'cv': 0},
      'req_0': {
        'module': 'music.musicasset.PlaylistBaseRead',
        'method': 'GetPlaylistByUin',
        'param': {'uin': '935624248'},
      },
    }),
    options: Options(
      contentType: 'application/json',
      headers: {
        'Referer': 'https://y.qq.com/',
        'Origin': 'https://y.qq.com',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    ),
  );
  dynamic body = resp.data;
  if (body is String) {
    try {
      body = jsonDecode(body);
    } catch (_) {}
  }
  final root = body is Map ? Map<String, dynamic>.from(body as Map) : <String, dynamic>{};
  print('HTTP ${resp.statusCode}, rawType=${resp.data.runtimeType}, rawLen=${resp.data.toString().length}');
  if (root['req_0'] == null) {
    print('full body: ${jsonEncode(root)}');
  }
  final data = root['req_0']?['data'];
  final vPlaylist = data?['v_playlist'] as List? ?? const [];
  print('HTTP ${resp.statusCode}, req_0 code=${root['req_0']?['code']}');
  if (vPlaylist.isEmpty) {
    print('req_0 raw: ${jsonEncode(root['req_0'])}');
  }
  for (final p in vPlaylist) {
    final m = p as Map;
    print('---');
    print('tid=${m['tid']} dirName=${m['dirName']} songNum=${m['songNum']}');
    for (final key in [
      'picUrl', 'bigpicUrl', 'albumPicUrl', 'layerUrl',
      'picurl', 'logo', 'cover',
    ]) {
      final v = m[key];
      if (v != null && '$v'.isNotEmpty) print('  $key = $v');
    }
  }
  if (vPlaylist.isNotEmpty) {
    print('=== full first item ===');
    print(jsonEncode(vPlaylist.first));
  }
}
