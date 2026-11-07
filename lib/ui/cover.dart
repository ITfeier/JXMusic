import 'dart:io';

import 'package:flutter/material.dart';
import '../services/api/http.dart' show jxNormalizeImageUrl;

/// 图片请求统一请求头。
///
/// 网易云（p1.music.126.net）和酷狗（imge.kugou.com）的 CDN 会对 Flutter
/// 默认的 `Dart/x.y (dart:io)` UA 直接返回 403，必须伪装成浏览器 UA 才能取图，
/// 否则所有封面都会落到渐变占位图。
const Map<String, String> jxImageHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  'Referer': 'https://music.163.com/',
};

bool jxIsNetworkSource(String src) {
  final s = src.trim().toLowerCase();
  return s.startsWith('http://') || s.startsWith('https://');
}

/// 统一封面渲染组件：
/// - 支持 http(s) 网络图（带浏览器 UA）与本地文件路径（本地音乐内嵌封面）
/// - 加载中/失败/空地址时统一回落到 [fallback]
class JXCoverImage extends StatelessWidget {
  final String src;
  final BoxFit fit;
  final int? cacheWidth;
  final Widget fallback;

  const JXCoverImage({
    super.key,
    required this.src,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.cacheWidth,
  });

  @override
  Widget build(BuildContext context) {
    final s = jxNormalizeImageUrl(src);
    if (s.isEmpty) return fallback;
    if (jxIsNetworkSource(s)) {
      return Image.network(
        s,
        fit: fit,
        headers: jxImageHeaders,
        cacheWidth: cacheWidth,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return Image.file(
      File(s),
      fit: fit,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}
