import 'dart:io';

/// 网易云封面 403 根因诊断（手动运行，需要联网）：
///   dart run tool/check_cover_image.dart [图片URL]
///
/// 对比两种 User-Agent 设置方式（UA 配置与 lib/ui/cover.dart 的
/// JXNetworkImage 保持一致）：
///   [A] HttpClient.userAgent = Chrome UA            → 修复后的写法，期望 200
///   [B] request.headers.add('User-Agent', Chrome)   → Flutter Image.network(headers:)
///       的旧写法：会与 dart:io 默认 `Dart/x.y (dart:io)` 组合成两段 UA，
///       网易云 CDN 返回 403（真机「封面全 403」的根因）。
///
/// 输出含 HTTP 状态与字节数，A 不是 200 时进程退出码为 1。
///
/// 注意：lib/ui/cover.dart 依赖 Flutter，纯 dart 工具无法直接 import，
/// 因此 UA 在这里复制一份（jxImageUserAgent 的同一字符串，改动需同步）。

/// 与 lib/ui/cover.dart 的 jxImageUserAgent 保持一致。
const String _chromeUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0 Safari/537.36';

/// 默认探测一张网易云歌单封面（500y500 缩略图，实测约 40KB）。
const String _defaultUrl =
    'https://p1.music.126.net/XtBk-KKRHFBHI87HZE9ljQ==/109951173904350931.jpg'
    '?param=500y500';

enum _UaMode { set, add }

class _ProbeResult {
  _ProbeResult(this.status, this.bytes, this.requestUserAgent);

  final int status;
  final int bytes;
  final List<String> requestUserAgent;
}

Future<_ProbeResult> _fetch(String url, {required _UaMode mode}) async {
  final client = HttpClient();
  // [A] 修复后的写法：UA 走 client.userAgent（单值，等价 headers.set）
  if (mode == _UaMode.set) client.userAgent = _chromeUa;
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('Referer', 'https://music.163.com/');
    // [B] 旧写法：add 会与 dart:io 默认 UA 组合成两段
    if (mode == _UaMode.add) {
      request.headers.add('User-Agent', _chromeUa);
    }
    final uaSent = List<String>.of(
      request.headers['user-agent'] ?? const <String>[],
    );
    final response = await request.close();
    var bytes = 0;
    await for (final chunk in response) {
      bytes += chunk.length;
    }
    return _ProbeResult(response.statusCode, bytes, uaSent);
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args.first : _defaultUrl;
  stdout.writeln('封面 URL: $url');

  final viaUserAgent = await _fetch(url, mode: _UaMode.set);
  stdout.writeln('');
  stdout.writeln('[A] HttpClient.userAgent = Chrome UA（修复后的写法，UA 单值）');
  stdout.writeln('    status=${viaUserAgent.status} bytes=${viaUserAgent.bytes}');
  stdout.writeln('    发送的 user-agent: ${viaUserAgent.requestUserAgent}');
  stdout.writeln('    结果: ${viaUserAgent.status == HttpStatus.ok ? 'PASS（200，可出图）' : 'FAIL（期望 200）'}');

  final viaAdd = await _fetch(url, mode: _UaMode.add);
  stdout.writeln('');
  stdout.writeln('[B] request.headers.add("User-Agent")（Flutter Image.network(headers:) 旧行为，UA 两段）');
  stdout.writeln('    status=${viaAdd.status} bytes=${viaAdd.bytes}');
  stdout.writeln('    发送的 user-agent: ${viaAdd.requestUserAgent}');
  stdout.writeln(
    '    对照: ${viaAdd.status == HttpStatus.forbidden ? '403（复现真机问题）' : 'status=${viaAdd.status}（与预期 403 不同，记录本机环境差异）'}',
  );

  if (viaUserAgent.status != HttpStatus.ok) {
    stderr.writeln('FAIL: 修复后的写法没有拿到 HTTP 200');
    exitCode = 1;
  }
}
