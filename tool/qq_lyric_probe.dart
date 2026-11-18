// 一次性探针：QQ client_search_cp t=7 歌词搜索原始字段确认
// dart run tool/qq_lyric_probe.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:dio/dio.dart';

Future<void> main() async {
  final dio = Dio(BaseOptions(
    validateStatus: (s) => s != null && s < 500,
    headers: {'Referer': 'https://y.qq.com/'},
  ));
  final resp = await dio.get(
    'https://c.y.qq.com/soso/fcgi-bin/client_search_cp',
    queryParameters: {
      'p': 1, 'n': 2, 'w': '周杰伦', 't': 7,
      'format': 'json', 'inCharset': 'utf8', 'outCharset': 'utf-8',
    },
  );
  final raw = resp.data;
  final root = raw is String ? jsonDecode(raw) as Map : raw as Map;
  final list = root['data']?['lyric']?['list'] as List? ?? const [];
  print('list 长度: ${list.length}');
  if (list.isNotEmpty) {
    final m = list.first as Map;
    print('keys: ${m.keys.toList()}');
    print(jsonEncode(m));
  }
  dio.close();
}
