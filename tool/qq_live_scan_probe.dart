// QQ 扫码登录端到端实扫探针：取码 → 落盘 PNG → 轮询 → 扫码确认后完整走
// check_sig → authorize → QQLogin 兑换链路（全部 _log 输出到控制台）。
// 用于隔离“应用/设备/网络”变量，直接验证兑换协议本身是否可用。
// 用法：dart run tool/qq_live_scan_probe.dart [PNG输出路径]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:jxmusic/services/api/qq_api.dart';

Future<void> main(List<String> args) async {
  final api = QQMusicApi();
  final created = await api.createQrLogin();
  if (created.qrUrl.isEmpty) {
    print('取码失败：${api.lastError}');
    exit(1);
  }
  final b64 = created.qrUrl.substring(created.qrUrl.indexOf(',') + 1);
  final png = base64Decode(b64);
  final out = args.isNotEmpty ? args.first : 'qq_qr_probe.png';
  final file = File(out);
  file.writeAsBytesSync(png);
  print('二维码已保存：${file.absolute.path}');
  print('请用手机 QQ「扫一扫」扫描这张图片（约 2 分钟内有效），'
      '本探针每 2 秒轮询一次…');
  for (var i = 0; i < 75; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final session = await api.pollQrLogin(created.key);
    if (session != null) {
      print('登录成功：${session.nickname} '
          'cookies=${session.cookies.keys.toList()}');
      exit(0);
    }
    if (api.qrScanConfirmed) {
      print('扫码已确认但兑换失败：${api.lastError}');
      exit(2);
    }
    final err = api.lastError;
    print('[${(i + 1) * 2}s] ${err ?? '等待扫码…'}');
    if (err != null && err.contains('过期')) exit(3);
  }
  print('超时未扫码（二维码已失效）');
  exit(4);
}
