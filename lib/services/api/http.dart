import 'dart:convert';
import 'package:dio/dio.dart';

/// 网络客户端统一配置
class JXHttp {
  static final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    },
  ))
    ..interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        // Referer 不再全局默认 music.163.com（对 QQ/酷狗是站外 Referer，
        // 服务端一旦收紧校验就会静默空结果）。未显式指定时按目标域补：
        // - 163.com → music.163.com；qq.com → y.qq.com；kugou.com → m.kugou.com
        // - 其它域不带 Referer
        if (options.headers['Referer'] == null) {
          final host = options.uri.host.toLowerCase();
          if (host.contains('163.com')) {
            options.headers['Referer'] = 'https://music.163.com/';
          } else if (host.contains('qq.com')) {
            options.headers['Referer'] = 'https://y.qq.com/';
          } else if (host.contains('kugou.com')) {
            options.headers['Referer'] = 'https://m.kugou.com/';
          }
        }
        handler.next(options);
      },
      onResponse: (resp, handler) {
        // 部分接口以 text/plain、text/html 返回 JSON 内容，Dio 默认不解码，
        // 统一在此将 JSON 字符串解析为 Map/List，保证上层可直接按 Map 取值。
        final data = resp.data;
        if (data is String) {
          final s = data.trim();
          if (s.startsWith('{') || s.startsWith('[')) {
            try {
              resp.data = jsonDecode(s);
            } catch (_) {
              // 非合法 JSON，保持原样
            }
          }
        }
        handler.next(resp);
      },
    ));
}

/// 规范化图片地址：
/// - 去掉首尾空白
/// - 协议相对地址（// 开头）补 https
/// - 接口返回的 http 地址统一升级为 https（Android 9+ 默认禁止明文 HTTP）
String jxNormalizeImageUrl(String? url) {
  if (url == null) return '';
  var u = url.trim();
  if (u.isEmpty) return '';
  if (u.startsWith('//')) u = 'https:$u';
  if (u.startsWith('http://')) {
    u = 'https://${u.substring('http://'.length)}';
  }
  return u;
}

/// 音频直链 http → https 升级：三家平台 CDN 均支持 https
/// （2026-11 实测 m80x.music.126.net / aqqmusic.tc.qq.com / sharefs.kugou.com
/// 明文与 https 同文件均可 200），而真机 libmpv 打开 http:// 直链会快速
/// 失败（hilog 取证「Failed to open」，~150ms），统一升级 https 播放。
String jxUpgradeHttps(String url) =>
    url.startsWith('http://') ? 'https://${url.substring(7)}' : url;

/// 平台登录态（扫码登录后填充，可持久化到 Hive）
class AccountSession {
  final int platform;
  final Map<String, String> cookies;
  final String nickname;
  final String? avatarUrl;

  const AccountSession({
    required this.platform,
    required this.cookies,
    required this.nickname,
    this.avatarUrl,
  });

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'cookies': cookies,
        'nickname': nickname,
        'avatarUrl': avatarUrl,
      };

  factory AccountSession.fromJson(Map<String, dynamic> json) {
    final rawCookies = json['cookies'];
    final cookies = <String, String>{};
    if (rawCookies is Map) {
      rawCookies.forEach((k, v) {
        cookies['$k'] = '$v';
      });
    }
    return AccountSession(
      platform: (json['platform'] as num?)?.toInt() ?? 0,
      cookies: cookies,
      nickname: json['nickname'] as String? ?? '',
      avatarUrl: json['avatarUrl'] as String?,
    );
  }
}
