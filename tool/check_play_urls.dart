import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// 播放链路诊断（手动运行）：
///   dart run tool/check_play_urls.dart
///
/// 对三个平台分别：搜索 → 过滤免费歌 → 解析直链 → 用 Range 实际下载前 4KB，
/// 判断"能搜到但放不了"到底是 解析失败 还是 CDN 拒绝。
Future<void> main() async {
  final apis = <MusicPlatformApi>[QQMusicApi(), NeteaseApi(), KuGouApi()];
  const queries = ['国际歌', '生日快乐', '卡农'];

  var totalOk = 0;
  var totalFail = 0;

  for (final api in apis) {
    const names = <String>['QQ音乐','网易云音乐','酷狗音乐'];
    final name = names[api.platform];
    print('');
    print('========== $name（platform=${api.platform}）==========');
    for (final q in queries) {
      List<Song> songs;
      try {
        songs = await api.searchSongs(q, size: 10);
      } catch (e) {
        print('  搜索「$q」异常: $e');
        continue;
      }
      final free = songs.where((s) => !s.vip).toList();
      print('  搜索「$q」: 共 ${songs.length} 首，免费 ${free.length} 首'
          '${songs.isNotEmpty ? '（示例: ${songs.first.title} / vip=${songs.first.vip} / id=${songs.first.id}）' : ''}');
      for (final s in songs.take(3)) {
        String? url;
        try {
          url = await api.getPlayUrl(s);
        } catch (e) {
          print('    ✗ ${s.title} 解析异常: $e');
          totalFail++;
          continue;
        }
        if (url == null || url.isEmpty) {
          print('    ✗ ${s.title}（vip=${s.vip}）无法解析直链');
          totalFail++;
          continue;
        }
        final probe = await _probe(url, s.platform);
        if (probe) {
          print('    ✓ ${s.title} 直链可下载');
          totalOk++;
        } else {
          print('    ✗ ${s.title} 直链下载失败 url=${_short(url)}');
          totalFail++;
        }
      }
    }
  }

  print('');
  print('========== 汇总：可播 $totalOk 条 / 失败 $totalFail 条 ==========');
}

Future<bool> _probe(String url, int platform) async {
  try {
    final headers = <String, String>{
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
      'Range': 'bytes=0-4095',
      if (platform == 0) 'Referer': 'https://y.qq.com/',
      if (platform == 1) 'Referer': 'https://music.163.com/',
      if (platform == 2) 'Referer': 'https://m.kugou.com/',
    };
    final r = await JXHttp.dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: headers,
        validateStatus: (s) => s != null && s < 500,
        followRedirects: true,
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    final bytes = r.data is List<int> ? r.data as List<int> : <int>[];
    final ct = r.headers.value('content-type') ?? '';
    final ok = (r.statusCode == 200 || r.statusCode == 206) &&
        bytes.length > 512 &&
        !ct.contains('text/html') &&
        !ct.contains('application/json');
    if (!ok) {
      print('      探测: HTTP=${r.statusCode} bytes=${bytes.length} ct=$ct');
    }
    return ok;
  } catch (e) {
    print('      探测异常: $e');
    return false;
  }
}

String _short(String url) =>
    url.length > 110 ? '${url.substring(0, 110)}…' : url;
