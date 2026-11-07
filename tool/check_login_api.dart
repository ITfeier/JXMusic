import '../lib/services/api/netease_api.dart';
import '../lib/services/api/qq_api.dart';

Future<void> main() async {
  final n = NeteaseApi();
  try {
    final r = await n.createQrLogin();
    print('netease OK qrUrl head: ${r.qrUrl.length > 60 ? r.qrUrl.substring(0, 60) : r.qrUrl}');
    print('netease OK key len: ${r.key.length}');
  } catch (e, st) {
    print('netease ERR: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  }
  final q = QQMusicApi();
  try {
    final r = await q.createQrLogin();
    print('qq OK qrUrl head: ${r.qrUrl.length > 80 ? r.qrUrl.substring(0, 80) : r.qrUrl}');
    print('qq OK key len: ${r.key.length}');
  } catch (e, st) {
    print('qq ERR: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  }
}
