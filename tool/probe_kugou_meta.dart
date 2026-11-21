// 临时探针：numeric specialid 的歌单元数据接口。
import 'dart:convert';

import 'package:dio/dio.dart';

const mobileUa =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

Future<void> main() async {
  final dio = Dio(BaseOptions(
    validateStatus: (code) => code != null && code < 500,
    headers: {'User-Agent': mobileUa},
  ));

  // 候选1：m.kugou.com/plist/info?specialid=xxx&json=true
  try {
    final resp = await dio.get(
      'https://m.kugou.com/plist/info/',
      queryParameters: {'specialid': 2509422, 'json': 'true'},
    );
    dynamic body = resp.data;
    if (body is String) {
      try {
        body = jsonDecode(body);
      } catch (_) {}
    }
    print('plist/info status=${resp.statusCode}');
    if (body is Map) {
      print('  top keys: ${body.keys.toList()}');
      final list = body['list'];
      if (list is Map) {
        print('  list keys: ${list.keys.toList().take(20).toList()}');
        print('  specialname=${list['specialname']}');
        print('  imgurl=${list['imgurl']}');
        print('  username=${list['username']}');
        final info = list['info'];
        if (info is List) print('  info.length=${info.length}');
      }
    } else {
      print('  body(300): ${'$body'.substring(0, 300)}');
    }
  } catch (e) {
    print('plist/info error: $e');
  }
}
