import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/ui/cover.dart';

/// 封面 URL / 请求头 / 自定义 ImageProvider 的纯函数与行为测试。
///
/// 重点锁两件事：
/// 1) 请求头里**绝不出现 User-Agent**（真机网易云 403 的根因是
///    `Image.network(headers:)` 用 headers.add 造成 UA 变成两段）；
/// 2) 网易云封面补 `?param=500y500` 缩略图（体积小、首屏快），失败重试一次。
void main() {
  group('jxCoverUrlVariants', () {
    const neteaseUrl =
        'https://p1.music.126.net/XtBk-KKRHFBHI87HZE9ljQ==/109951173904350931.jpg';

    test('网易云无 param：首选补 param=500y500，重试回退原图地址', () {
      final variants = jxCoverUrlVariants(neteaseUrl);
      expect(variants.length, 2);
      expect(variants.first, '$neteaseUrl?param=500y500');
      expect(variants.last, neteaseUrl, reason: '首个候选失败后回退原地址');
    });

    test('网易云已带 param：首选原地址，重试去掉 param（其余 query 保留）', () {
      const url = 'https://p3.music.126.net/a==/1.jpg?param=200y200&v=1';
      final variants = jxCoverUrlVariants(url);
      expect(variants.length, 2);
      expect(variants.first, url);
      expect(variants.last, 'https://p3.music.126.net/a==/1.jpg?v=1');
    });

    test('网易云已带其它 query（如老接口 imageView）：保持原地址不动，避免破坏参数', () {
      const url =
          'https://p1.music.126.net/a==/1.jpg?imageView&thumbnail=426y426';
      expect(jxCoverUrlVariants(url), [url]);
    });

    test('非网易云域名：只有原地址一个候选', () {
      expect(
        jxCoverUrlVariants('https://y.gtimg.cn/music/photo_new/a.jpg'),
        ['https://y.gtimg.cn/music/photo_new/a.jpg'],
      );
      expect(
        jxCoverUrlVariants('https://imge.kugou.com/stdmusic/a.jpg'),
        ['https://imge.kugou.com/stdmusic/a.jpg'],
      );
    });

    test('协议相对地址补 https、空地址返回空列表', () {
      expect(
        jxCoverUrlVariants('//p1.music.126.net/a==/1.jpg').first,
        'https://p1.music.126.net/a==/1.jpg?param=500y500',
      );
      expect(jxCoverUrlVariants(''), isEmpty);
      expect(jxCoverUrlVariants('   '), isEmpty);
    });
  });

  group('jxImageRequestHeaders（只放 Referer，不带 UA）', () {
    test('任何域名都不包含 User-Agent（含大小写变体）', () {
      const urls = [
        'https://p1.music.126.net/a.jpg',
        'https://y.gtimg.cn/a.jpg',
        'https://thirdqq.qlogo.cn/a.jpg',
        'https://imge.kugou.com/a.jpg',
        'https://example.com/a.jpg',
      ];
      for (final url in urls) {
        final headers = jxImageRequestHeaders(url);
        expect(headers.keys.length, 1, reason: '只允许 Referer: $url');
        for (final key in headers.keys) {
          expect(
            key.toLowerCase(),
            isNot('user-agent'),
            reason: 'UA 必须由 HttpClient.userAgent 设置，不能走请求头（add 会重复→403）',
          );
        }
      }
    });

    test('Referer 按域名正确', () {
      expect(
        jxImageRequestHeaders('https://p1.music.126.net/a.jpg')['Referer'],
        'https://music.163.com/',
      );
      expect(
        jxImageRequestHeaders('https://y.gtimg.cn/a.jpg')['Referer'],
        'https://y.qq.com/',
      );
      expect(
        jxImageRequestHeaders('https://thirdqq.qlogo.cn/a.jpg')['Referer'],
        'https://y.qq.com/',
      );
      expect(
        jxImageRequestHeaders('https://imge.kugou.com/a.jpg')['Referer'],
        'https://m.kugou.com/',
      );
      // 兜底保持网易云 Referer（与原行为一致）
      expect(
        jxImageRequestHeaders('https://example.com/a.jpg')['Referer'],
        'https://music.163.com/',
      );
    });
  });

  group('JXNetworkImage（自定义 Provider 基础行为）', () {
    test('== / hashCode：url + scale + headers 相同即相等', () {
      final headers = jxImageRequestHeaders('https://p1.music.126.net/a.jpg');
      final a = JXNetworkImage('https://p1.music.126.net/a.jpg', headers: headers);
      final b = JXNetworkImage('https://p1.music.126.net/a.jpg', headers: headers);
      final c = JXNetworkImage('https://p1.music.126.net/b.jpg', headers: headers);
      final d = JXNetworkImage('https://p1.music.126.net/a.jpg', headers: null);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c), reason: 'URL 不同不能相等');
      expect(a, isNot(d), reason: 'headers 不同不能相等');
    });

    test('obtainKey 返回自身，供 ImageCache 作 key', () async {
      const image = JXNetworkImage('https://p1.music.126.net/a.jpg');
      final key = await image.obtainKey(ImageConfiguration.empty);
      expect(key, same(image));
    });

    test('toString 带 URL，方便日志定位', () {
      const image = JXNetworkImage('https://p1.music.126.net/a.jpg');
      expect(image.toString(), contains('p1.music.126.net'));
    });
  });

  group('JXCoverImage 网络失败诊断（真机 logcat 用）', () {
    // cacheWidth 走 null（直接用 JXNetworkImage）与 300（ResizeImage 包装）两条路径，
    // 真实页面（GlassCover/JXCover）都传了 cacheWidth，两条都要锁住。
    for (final cacheWidth in <int?>[null, 300]) {
      testWidgets(
          '失败时打印 URL+error，并自动重试一次后回落 fallback（cacheWidth=$cacheWidth）',
          (tester) async {
        final logs = <String>[];
        final original = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) logs.add(message);
        };
        addTearDown(() => debugPrint = original);

        // 测试环境的 HttpClient 被 flutter_test 替换为固定返回 400，必然失败，
        // 正好用来锁「诊断日志 + 仅重试一次」的行为（不会真的联网）。
        await tester.pumpWidget(
          MaterialApp(
            home: JXCoverImage(
              src: 'https://p1.music.126.net/a==/1.jpg',
              cacheWidth: cacheWidth,
              fallback: const Text('FALLBACK'),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        // debugPrint 是 foundation 调试变量，必须在测试体内恢复，
        // 否则 testWidgets 收尾的 debugAssertAllFoundationVarsUnset 会失败。
        debugPrint = original;

        expect(find.text('FALLBACK'), findsOneWidget, reason: '失败后必须回落占位');
        final failed =
            logs.where((l) => l.contains('[JXMusic] 封面加载失败')).toList();
        final retried =
            logs.where((l) => l.contains('[JXMusic] 封面重试仍失败')).toList();
        expect(failed.length, 1, reason: '首次失败要打印诊断日志');
        expect(retried.length, 1, reason: '只重试一次，不能无限重试');
        // 首选是网易云缩略图地址；重试回退原图地址
        expect(failed.single, contains('param=500y500'));
        expect(failed.single, contains('statusCode: 400'));
        expect(retried.single, isNot(contains('param=')));
      });
    }
  });
}
