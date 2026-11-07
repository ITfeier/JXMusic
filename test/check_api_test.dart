import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';

void main() {
  test('login api check', () async {
    final n = NeteaseApi();
    try {
      final r = await n.createQrLogin();
      print('netease OK key len=${r.key.length} qrUrl head=${r.qrUrl.length > 50 ? r.qrUrl.substring(0, 50) : r.qrUrl}');
    } catch (e, st) {
      print('netease ERR: $e');
      print(st.toString().split('\n').take(8).join('\n'));
    }
    final q = QQMusicApi();
    try {
      final r = await q.createQrLogin();
      print('qq OK qrUrl head=${r.qrUrl.length > 80 ? r.qrUrl.substring(0, 80) : r.qrUrl} key len=${r.key.length}');
    } catch (e, st) {
      print('qq ERR: $e');
      print(st.toString().split('\n').take(8).join('\n'));
    }
  }, timeout: const Timeout(Duration(minutes: 2)),
      // 需要真实联网的接口连通性排查脚本，默认跳过，避免 CI/本地 `flutter test` 变红。
      // 手动运行：flutter test test/check_api_test.dart --run-skipped
      skip: '需要联网的扫码接口探测，按需用 --run-skipped 手动执行');
}
