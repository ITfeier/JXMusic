/// 歌词行
class LyricLine {
  final int time; // 毫秒
  final String text;

  const LyricLine(this.time, this.text);
}

/// 歌词解析工具（支持 LRC 与简易逐字）
class LyricParser {
  static final RegExp _timeReg =
      RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// 解析 LRC 文本 -> 排序后的歌词行
  static List<LyricLine> parseLrc(String lrc) {
    if (lrc.isEmpty) return const [];
    final lines = <LyricLine>[];
    for (final line in lrc.split('\n')) {
      final matches = _timeReg.allMatches(line).toList();
      if (matches.isEmpty) continue;
      final text = line
          .replaceAll(_timeReg, '')
          .trim();
      for (final m in matches) {
        final min = int.tryParse(m.group(1) ?? '0') ?? 0;
        final sec = int.tryParse(m.group(2) ?? '0') ?? 0;
        final fracRaw = m.group(3) ?? '0';
        final frac = int.tryParse(fracRaw) ?? 0;
        final ms = min * 60000 + sec * 1000 +
            (fracRaw.length == 2 ? frac * 10 : frac);
        lines.add(LyricLine(ms, text));
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}
