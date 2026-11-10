import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/models/lyric.dart';

/// R1.4 LRC 解析修正回归测试：
/// - 1 位小数 ×100（修复前按 ×1，歌词慢约 0.4s）；
/// - 过滤无文本时间标签行；
/// - CRLF / CR 换行；
/// - 一行多时间标签；
/// - `[offset:±ms]` 整体偏移。
void main() {
  group('小数位毫秒换算', () {
    test('1 位小数 ×100： [00:01.5] = 1500ms', () {
      final lines = LyricParser.parseLrc('[00:01.5]词');
      expect(lines.length, 1);
      expect(lines.first.time, 1500,
          reason: '1 位小数应×100（修复前是×1，差约 0.4s）');
      expect(lines.first.text, '词');
    });

    test('2 位小数 ×10： [00:01.50] = 1500ms、[00:01.05] = 1050ms', () {
      expect(LyricParser.parseLrc('[00:01.50]a').first.time, 1500);
      expect(LyricParser.parseLrc('[00:01.05]a').first.time, 1050);
    });

    test('3 位小数 ×1： [00:01.500] = 1500ms', () {
      expect(LyricParser.parseLrc('[00:01.500]a').first.time, 1500);
      expect(LyricParser.parseLrc('[00:01.005]a').first.time, 1005);
    });

    test('整分钟进位： [01:02.3] = 62300ms', () {
      expect(LyricParser.parseLrc('[01:02.3]a').first.time, 62300);
    });
  });

  group('行过滤与换行', () {
    test('纯时间标签行（无文本）不生成歌词行', () {
      final lines =
          LyricParser.parseLrc('[00:01.00]\n[00:02.00]   \n[00:03.00]词');
      expect(lines.length, 1);
      expect(lines.first.text, '词');
      expect(lines.first.time, 3000);
    });

    test('元信息行（[ti:]/[ar:]/[by:]）忽略', () {
      final lines = LyricParser.parseLrc(
          '[ti:标题]\n[ar:歌手]\n[by:制作]\n[00:01.00]词');
      expect(lines.length, 1);
      expect(lines.first.text, '词');
    });

    test('CRLF 换行（Windows）与 CR 换行都能解析', () {
      final crlf = LyricParser.parseLrc('[00:01.00]第一行\r\n[00:02.00]第二行');
      expect(crlf.length, 2);
      expect(crlf[0].text, '第一行');
      expect(crlf[1].text, '第二行');

      final cr = LyricParser.parseLrc('[00:03.00]一\r[00:04.00]二');
      expect(cr.length, 2);
    });

    test('空文本返回空列表', () {
      expect(LyricParser.parseLrc(''), isEmpty);
      expect(LyricParser.parseLrc('   \n  '), isEmpty);
    });
  });

  group('多时间标签与排序', () {
    test('一行多时间标签展开为多行（文本相同）', () {
      final lines = LyricParser.parseLrc('[00:01.00][00:05.00]重复句');
      expect(lines.length, 2);
      expect(lines[0].time, 1000);
      expect(lines[1].time, 5000);
      expect(lines[0].text, '重复句');
      expect(lines[1].text, '重复句');
    });

    test('输出按时间升序排序（输入乱序也排序）', () {
      final lines = LyricParser.parseLrc(
          '[00:03.00]后\n[00:01.50]前\n[00:02.00]中');
      expect(lines.map((e) => e.text).toList(), ['前', '中', '后']);
      expect(lines.map((e) => e.time).toList(), [1500, 2000, 3000]);
    });
  });

  group('[offset:±ms] 整体偏移', () {
    test('正值表示歌词提前：time = 原始 - offset', () {
      final lines = LyricParser.parseLrc('[offset:+500]\n[00:10.00]词');
      expect(lines.first.time, 9500);
    });

    test('负值表示歌词延后：time = 原始 - (-offset)', () {
      final lines = LyricParser.parseLrc('[offset:-300]\n[00:10.00]词');
      expect(lines.first.time, 10300);
    });

    test('offset 行自身不生成歌词行，且大小写/空格容错', () {
      final lines = LyricParser.parseLrc('[Offset: +200]\n[00:01.00]词');
      expect(lines.length, 1);
      expect(lines.first.time, 800);
    });

    test('无 offset 时按原始时间', () {
      expect(LyricParser.parseLrc('[00:10.00]词').first.time, 10000);
    });
  });
}
