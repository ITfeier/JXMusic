import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:hive/hive.dart';

import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// 与 lib/core/constants.dart 的 JXConstants.hiveBoxAccounts 保持一致；
/// 不直接 import constants（其带 flutter/material 依赖，纯 dart run 跑不了）。
const String _kAccountsBox = 'jx_accounts';

/// 一次性诊断探针（不在 App 内运行）：
///
/// ```
/// dart run -DJX_PROBE=true tool/probe_playlists.dart <设备上拉取的 app_flutter 目录>
/// ```
///
/// 读取设备 Hive 账号盒子（jx_accounts.hive）里的真实登录态，
/// 用 App 同一份 API 代码复现「收藏歌单」tab 的三平台 userPlaylists 拉取，
/// 配合 `-DJX_PROBE=true` 打印平台原始响应，定位「登录了但 0 个歌单」的根因。
Future<void> main(List<String> args) async {
  final dir = args.isNotEmpty
      ? args.first
      : '${Directory.current.path}${Platform.pathSeparator}.dart_tool';
  final accountsPath =
      '$dir${Platform.pathSeparator}$_kAccountsBox.hive';
  if (!File(accountsPath).existsSync()) {
    stderr.writeln('找不到 $accountsPath');
    exitCode = 2;
    return;
  }
  final box = await Hive.openBox<Map>(
    _kAccountsBox,
    bytes: File(accountsPath).readAsBytesSync(),
  );

  final apis = <int, dynamic>{};
  for (var p = 0; p <= 2; p++) {
    final raw = box.get('platform_$p');
    final session = raw == null ? null : AccountSession.fromJson(
        Map<String, dynamic>.from(raw.cast<String, dynamic>()));
    switch (p) {
      case 0:
        apis[p] = QQMusicApi();
      case 1:
        apis[p] = NeteaseApi();
      default:
        apis[p] = KuGouApi();
    }
    if (session != null) {
      (apis[p] as dynamic).restoreSession(session);
      stdout.writeln('platform_$p 已登录: nickname=${session.nickname} '
          'cookies=${session.cookies.keys.toList()}');
    } else {
      stdout.writeln('platform_$p 未登录（盒子无 session）');
    }
  }

  final names = {0: 'QQ', 1: '网易云', 2: '酷狗'};
  for (final p in const [0, 1, 2]) {
    try {
      final lists =
          await (apis[p] as dynamic).userPlaylists() as List<dynamic>;
      stdout.writeln('${names[p]}: ${lists.length} 个歌单');
      // 每平台逐个歌单试拉详情歌曲（诊断「详情暂无歌曲」类问题）
      for (final pl in lists) {
        try {
          final songs = await (apis[p] as dynamic)
              .playlistSongs(pl) as List<dynamic>;
          stdout.writeln('${names[p]} 歌单「${pl.title}」(id=${pl.id}): '
              '${songs.length} 首');
        } catch (e) {
          stdout.writeln('${names[p]} 歌单「${pl.title}」详情: 抛错 $e');
        }
      }
    } catch (e) {
      stdout.writeln('${names[p]}: 抛错 $e');
    }
  }

  // 端点实验：隐私歌单（如 2902307374）在不同 detail 端点下的可达性
  final rawSession = box.get('platform_1');
  if (rawSession is Map) {
    final session = AccountSession.fromJson(
        Map<String, dynamic>.from(rawSession.cast<String, dynamic>()));
    final cookie = session.cookies.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
    const pid = '2902307374';
    for (final path in const [
      '/api/v3/playlist/detail',
      '/api/v6/playlist/detail',
      '/api/playlist/detail/dynamic',
    ]) {
      try {
        final r = await JXHttp.dio.get('https://music.163.com$path',
            queryParameters: {'id': pid, 'n': '10'},
            options: dio.Options(headers: {
              'Cookie': cookie,
              'Referer': 'https://music.163.com/',
            }));
        final raw = jsonEncode(r.data);
        stdout.writeln('[exp] $path -> '
            '${raw.substring(0, raw.length > 300 ? 300 : raw.length)}');
      } catch (e) {
        stdout.writeln('[exp] $path -> 抛错 $e');
      }
    }
  }
  await box.close();
}
