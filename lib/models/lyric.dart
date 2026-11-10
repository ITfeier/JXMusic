/// 歌词行
class LyricLine {
  final int time; // 毫秒
  final String text;

  const LyricLine(this.time, this.text);

  @override
  String toString() => 'LyricLine($time, $text)';
}

/// 歌词解析工具（支持 LRC 与简易逐字）
class LyricParser {
  static final RegExp _timeReg =
      RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// LRC 整体偏移标签：`[offset:+500]`（单位毫秒，正值表示歌词提前）
  static final RegExp _offsetReg =
      RegExp(r'\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);

  /// 解析 LRC 文本 -> 按时间升序排序的歌词行（PRD R1.4）。
  ///
  /// - 小数位换算：1 位 ×100、2 位 ×10、3 位 ×1；
  /// - 过滤无文本行（如 `[02:21.989]` 单独一行）与元信息行（`[ti:...]`）；
  /// - 兼容 CRLF / CR 换行；
  /// - 一行多个时间标签展开成多行；
  /// - `[offset:±ms]` 整体偏移（`time = 原始时间 - offset`）。
  static List<LyricLine> parseLrc(String lrc) {
    if (lrc.isEmpty) return const [];
    final normalized = lrc.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    var offsetMs = 0;
    final offsetMatch = _offsetReg.firstMatch(normalized);
    if (offsetMatch != null) {
      offsetMs = int.tryParse(offsetMatch.group(1) ?? '') ?? 0;
    }
    final lines = <LyricLine>[];
    for (final line in normalized.split('\n')) {
      final matches = _timeReg.allMatches(line).toList();
      if (matches.isEmpty) continue;
      final text = line.replaceAll(_timeReg, '').trim();
      // 纯时间标签行没有歌词文本（常见于尾行），不生成歌词行
      if (text.isEmpty) continue;
      for (final m in matches) {
        lines.add(LyricLine(_timestampMs(m) - offsetMs, text));
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  static int _timestampMs(RegExpMatch m) {
    final min = int.tryParse(m.group(1) ?? '0') ?? 0;
    final sec = int.tryParse(m.group(2) ?? '0') ?? 0;
    final fracRaw = m.group(3) ?? '';
    var frac = int.tryParse(fracRaw) ?? 0;
    // 小数位换算：`[00:01.5]`=1 位=500ms，`[00:01.50]`=2 位=500ms，
    // `[00:01.500]`=3 位=500ms。修复前 1 位按 ×1 ∈ [0,9]ms（慢约 0.4s）。
    if (fracRaw.length == 1) {
      frac *= 100;
    } else if (fracRaw.length == 2) {
      frac *= 10;
    }
    return min * 60000 + sec * 1000 + frac;
  }
}
