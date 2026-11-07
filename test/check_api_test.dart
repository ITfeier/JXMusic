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
  }, timeout: const Timeout(Duration(minutes: 2)));
}
