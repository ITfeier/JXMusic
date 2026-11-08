import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// 回归：QQ 歌单广场接口默认返回 GBK（charset=gb2312），Dio 按 UTF-8 解码会把
/// 中文歌单标题解成替换字符。修复方式是在请求里显式带 inCharset/outCharset=utf-8。
/// 这里把「可测的 URI 构造」锁进单测，防止日后清理参数时把乱码 bug 带回来。
void main() {
  group('QQ 歌单广场请求 URI（GBK 乱码回归）', () {
    test('必须带 inCharset/outCharset=utf-8', () {
      final uri = QQMusicApi.dissByTagUri(page: 1, size: 20, rnd: 1234567890);
      expect(uri.scheme, 'https');
      expect(uri.host, 'c.y.qq.com');
      expect(uri.path, '/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg');
      expect(uri.queryParameters['inCharset'], 'utf-8');
      expect(uri.queryParameters['outCharset'], 'utf-8');
      // 直接断言最终 URI 文本，模拟 Dio 实际消费的字符串
      expect(uri.toString(), contains('inCharset=utf-8'));
      expect(uri.toString(), contains('outCharset=utf-8'));
    });

    test('page/size 正确映射为 sin/ein（首页与全部歌单页共用）', () {
      final first = QQMusicApi.dissByTagUri(page: 1, size: 20, rnd: 1);
      expect(first.queryParameters['sin'], '0');
      expect(first.queryParameters['ein'], '19');

      final second = QQMusicApi.dissByTagUri(page: 2, size: 20, rnd: 1);
      expect(second.queryParameters['sin'], '20');
      expect(second.queryParameters['ein'], '39');
    });

    test('其余业务参数固定，rnd 可注入', () {
      final uri = QQMusicApi.dissByTagUri(page: 3, size: 10, rnd: 42);
      expect(uri.queryParameters['categoryId'], '10000000');
      expect(uri.queryParameters['sortId'], '5');
      expect(uri.queryParameters['format'], 'json');
      expect(uri.queryParameters['rnd'], '42');
      expect(uri.queryParameters['sin'], '20');
      expect(uri.queryParameters['ein'], '29');
    });
  });
}
