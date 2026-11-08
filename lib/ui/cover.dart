import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/api/http.dart' show jxNormalizeImageUrl;

/// 图片请求 UA（浏览器）。
///
/// 网易云（p1/p2/p3.music.126.net）等 CDN 对 Flutter/dart:io 默认的
/// `Dart/x.y (dart:io)` UA 返回 403，必须伪装成浏览器 UA。
///
/// **关键坑（真机「网易云封面全 403」的根因）**：UA 只能通过
/// `HttpClient.userAgent` 设置（单值，等价 `headers.set`），**不能**塞进
/// `Image.network(headers:)`——Flutter 的 NetworkImage 内部用
/// `request.headers.add(name, value)`，会与 dart:io 默认 UA 组合成
/// `Dart/3.13 (dart:io), Mozilla/5.0 ...` 两段 UA，网易云对组合 UA 返回 403。
/// 宿主 dart:io 实测：add/组合 UA → 403，set/单独 Chrome UA → 200。
/// 所以 [JXNetworkImage] 改用共享 HttpClient 的 `userAgent` 属性设 UA，
/// 请求头里只 `set` Referer。改这里前请先读 [JXNetworkImage] 的注释。
const String jxImageUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0 Safari/537.36';

bool jxIsNetworkSource(String src) {
  final s = src.trim().toLowerCase();
  return s.startsWith('http://') || s.startsWith('https://');
}

/// 是否网易云图片 CDN（p1/p2/p3.music.126.net 等）。
bool jxIsNeteaseImageHost(String host) {
  final h = host.toLowerCase();
  return h.endsWith('126.net') || h.endsWith('127.net');
}

/// 图片请求头（纯函数，便于单测）：**只返回 Referer，绝不包含 User-Agent**。
///
/// UA 由 [JXNetworkImage] 的共享 HttpClient 统一设置；参见 [jxImageUserAgent]
/// 里记录的 add/set 坑。按域名给来源：
/// - 网易云 CDN：`https://music.163.com/`
/// - QQ 音乐图片（y.gtimg.cn / qlogo.cn 等）：`https://y.qq.com/`
/// - 酷狗图片（imge.kugou.com 等）：`https://m.kugou.com/`
Map<String, String> jxImageRequestHeaders(String url) {
  return {'Referer': _jxImageRefererFor(url)};
}

String _jxImageRefererFor(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.endsWith('gtimg.cn') ||
      host.endsWith('qlogo.cn') ||
      host.endsWith('qq.com')) {
    return 'https://y.qq.com/';
  }
  if (host.endsWith('kugou.com')) {
    return 'https://m.kugou.com/';
  }
  return 'https://music.163.com/';
}

/// 封面 URL 的候选变体（纯函数，便于单测）。
///
/// 真机反馈：首页网易云推荐歌单封面全部回落渐变，同页 QQ/酷狗正常。
/// 实测网易云接口给的 `coverImgUrl` 多是**原图直链**（其中一张约 9MB），
/// 移动端加载慢/容易超时，加载完成前 UI 一直是渐变占位。
/// 网易云 CDN 支持 `?param=宽y高` 缩略图（实测同一张图 500y500 仅约 40KB，
/// 原图 122KB/9MB 不等），因此把「补 param=500y500」作为首选、原图地址作为
/// 失败后的一次重试候选；已带 param 的地址则反过来（首选原样、重试去掉 param）。
/// 非网易云域名只返回原地址；已有其它 query（如 imageView）时也不改动，
/// 避免重新编码改变服务端行为。
///
/// 注意：`?param` 只改善体积/速度，**不是** 403 的修复；403 的根因是重复 UA，
/// 见 [JXNetworkImage]。
List<String> jxCoverUrlVariants(String url) {
  final u = jxNormalizeImageUrl(url);
  if (u.isEmpty) return const [];
  final uri = Uri.tryParse(u);
  if (uri == null) return [u];
  if (!jxIsNeteaseImageHost(uri.host)) return [u];
  final params = Map<String, String>.from(uri.queryParameters);
  if (params.containsKey('param')) {
    params.remove('param');
    final without =
        uri.replace(queryParameters: params.isEmpty ? null : params).toString();
    return [u, without];
  }
  // 已有其它 query（如老接口的 imageView&thumbnail=...）时不要改动，
  // 避免重新编码把无值参数变成 `key=` 改变服务端行为。
  if (uri.query.isNotEmpty) return [u];
  final withParam = uri.replace(
    queryParameters: {'param': '500y500'},
  );
  return [withParam.toString(), u];
}

/// 封面加载失败诊断日志：真机用 `adb logcat | grep "JXMusic 封面"` 定位。
/// 只打印图片 URL 与异常本身，不含登录态/个人信息。
void jxLogCoverFailure(String url, Object error, {bool retried = false}) {
  final tag = retried ? '封面重试仍失败' : '封面加载失败';
  debugPrint('[JXMusic] $tag url=$url error=$error');
}

/// 自定义网络图片 Provider：行为对齐 Flutter 的 [NetworkImage]，但避免
/// 「`headers.add('User-Agent')` → UA 变成两段 → 网易云 403」的坑。
///
/// - 共享一个 `HttpClient`，用 `userAgent` 属性设置浏览器 UA（单值）；
/// - 每个请求只用 `headers.set` 追加 Referer 等自定义头，**绝不 set/add UA**；
/// - 非 200 抛 [NetworkImageLoadException]（带 statusCode，日志里能直接看到 403/404）；
/// - 失败时从 ImageCache 清掉自己（下同 URL 重试会真正重新发请求）。
///
/// 为什么不能用 `Image.network(headers:)`：Flutter 3.47.8 的
/// `packages/flutter/lib/src/painting/_network_image_io.dart` 对 headers 用
/// `request.headers.add(name, value)`，dart:io 默认 UA 已存在，服务端收到
/// `Dart/3.13 (dart:io), Mozilla/5.0 ...`；网易云 CDN 对这种组合 UA 返回 403。
@immutable
class JXNetworkImage extends ImageProvider<JXNetworkImage> {
  const JXNetworkImage(this.url, {this.scale = 1.0, this.headers});

  final String url;
  final double scale;

  /// 只放 Referer 等自定义头；**不要包含 User-Agent**（见类注释）。
  final Map<String, String>? headers;

  // 与 Flutter NetworkImage 一致：autoUncompress=false，
  // 由 consolidateHttpClientResponseBytes 负责解压并回传字节进度。
  // UA 用 userAgent 属性设置（单值），不是请求头。
  static final HttpClient _httpClient = HttpClient()
    ..autoUncompress = false
    ..userAgent = jxImageUserAgent;

  @override
  Future<JXNetworkImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<JXNetworkImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    JXNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    // chunkEvents 的所有权交给 _loadAsync：由它负责在加载完成/失败时关闭。
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<JXNetworkImage>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    JXNetworkImage key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      assert(key == this);
      final resolved = Uri.base.resolve(key.url);
      final request = await _httpClient.getUrl(resolved);
      // 只用 set：add 会与 dart:io 默认 UA 组合（见类注释，网易云 403 根因）。
      key.headers?.forEach((name, value) => request.headers.set(name, value));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        // 服务端可能只是暂时不可用：清掉缓存，后续重试仍会真正请求。
        await response.drain<List<int>>(<int>[]);
        throw NetworkImageLoadException(
          statusCode: response.statusCode,
          uri: resolved,
        );
      }
      final bytes = await consolidateHttpClientResponseBytes(
        response,
        onBytesReceived: (int cumulative, int? total) {
          chunkEvents.add(
            ImageChunkEvent(
              cumulativeBytesLoaded: cumulative,
              expectedTotalBytes: total,
            ),
          );
        },
      );
      if (bytes.lengthInBytes == 0) {
        throw Exception('JXNetworkImage 是空文件: $resolved');
      }
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (e) {
      // 失败时图片可能还挂在 ImageCache 里，清掉保证重试会重新请求。
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      // ignore: unawaited_futures
      chunkEvents.close().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'painting library',
            context: ErrorDescription(
              'while closing chunkEvents stream in JXNetworkImage.load',
            ),
          ),
        );
      });
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is JXNetworkImage &&
        other.url == url &&
        other.scale == scale &&
        mapEquals(other.headers, headers);
  }

  @override
  int get hashCode => Object.hash(url, scale, _headersHash(headers));

  static int? _headersHash(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return null;
    final keys = headers.keys.toList()..sort();
    return Object.hashAll([for (final k in keys) Object.hash(k, headers[k])]);
  }

  @override
  String toString() =>
      'JXNetworkImage("$url", scale: ${scale.toStringAsFixed(1)}, headers: $headers)';
}

/// 统一封面渲染组件：
/// - 支持 http(s) 网络图（[JXNetworkImage]，UA 由 HttpClient.userAgent 设置）
///   与本地文件路径（本地音乐内嵌封面）
/// - 加载中/失败/空地址时统一回落到 [fallback]
/// - 网络图失败会打印诊断日志并自动重试一次（网易云换另一种 URL 形式）
class JXCoverImage extends StatefulWidget {
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
  State<JXCoverImage> createState() => _JXCoverImageState();
}

class _JXCoverImageState extends State<JXCoverImage> {
  /// 0 = 首选地址；1 = 失败后的一次重试（网易云换另一种 URL 形式）。
  int _attempt = 0;

  @override
  void didUpdateWidget(covariant JXCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表复用/换歌时 src 会变：重试状态必须复位，否则新图直接显示占位。
    if (oldWidget.src != widget.src) _attempt = 0;
  }

  void _onNetworkError(String url, Object error) {
    jxLogCoverFailure(url, error, retried: _attempt > 0);
    if (_attempt > 0) return;
    _attempt = 1;
    // errorBuilder 在 build 期间同步调用，不能直接 setState，放到下一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// 网络图的 provider：需要限制解码尺寸时用 ResizeImage 包一层。
  ImageProvider<Object> _providerFor(String url) {
    final base = JXNetworkImage(url, headers: jxImageRequestHeaders(url));
    final cacheWidth = widget.cacheWidth;
    if (cacheWidth == null) return base;
    return ResizeImage(base, width: cacheWidth, allowUpscaling: false);
  }

  @override
  Widget build(BuildContext context) {
    final normalized = jxNormalizeImageUrl(widget.src);
    if (normalized.isEmpty) return widget.fallback;
    if (!jxIsNetworkSource(normalized)) {
      return Image.file(
        File(normalized),
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        errorBuilder: (_, error, _) {
          debugPrint('[JXMusic] 本地封面读取失败 path=$normalized error=$error');
          return widget.fallback;
        },
      );
    }
    final variants = jxCoverUrlVariants(normalized);
    final index = _attempt < variants.length ? _attempt : variants.length - 1;
    final url = variants[index];
    return Image(
      // key 带上重试序号：同一 URL 重试时也能强制重新发起请求
      key: ValueKey('$_attempt|$url'),
      image: _providerFor(url),
      fit: widget.fit,
      // 首帧解码完成前显示占位（替代 Image.network 的 loadingBuilder）
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return widget.fallback;
      },
      errorBuilder: (context, error, stackTrace) {
        _onNetworkError(url, error);
        return widget.fallback;
      },
    );
  }
}
