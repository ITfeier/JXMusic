import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// QQ 扫码轮询响应解析的回归测试。
///
/// 背景：真实响应 `ptuiCB('66','0','','0','二维码未失效。', '')` 最后一项前有空格，
/// 旧实现用固定分组正则匹配，导致正常等待态被误判为"轮询返回异常内容"。
void main() {
  test('等待态 66：最后一项前带空格也能解析', () {
    final cb = parsePtuiCb("ptuiCB('66','0','','0','二维码未失效。', '')");
    expect(cb, isNotNull);
    expect(cb!.code, '66');
    expect(cb.redirectUrl, isEmpty);
  });

  test('待确认 67 / 过期 65 / 参数错误 7', () {
    expect(parsePtuiCb("ptuiCB('67','0','','0','已扫码待确认', '')")!.code, '67');
    expect(parsePtuiCb("ptuiCB('65','0','','0','二维码已失效。', '')")!.code, '65');
    expect(
      parsePtuiCb("ptuiCB('7','0','','0','提交参数错误，请检查。', '')")!.code,
      '7',
    );
  });

  test('登录成功 0：能取出跳转 URL 与昵称', () {
    const text = "ptuiCB('0','0',"
        "'https://ptlogin2.qq.com/check_sig?uin=123456&ptsigx=abc123&s_url=x','0',"
        "'登录成功！','李先森')";
    final cb = parsePtuiCb(text);
    expect(cb, isNotNull);
    expect(cb!.code, '0');
    expect(cb.redirectUrl, contains('uin=123456'));
    expect(cb.redirectUrl, contains('ptsigx=abc123'));
    expect(cb.nickname, '李先森');
  });

  test('字段数不足/无 ptuiCB 时返回 null 而不是抛出', () {
    expect(parsePtuiCb(''), isNull);
    expect(parsePtuiCb('<html>403 Forbidden</html>'), isNull);
    expect(parsePtuiCb("ptuiCB('66')")?.code, '66');
  });
}
