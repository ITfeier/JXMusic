// 探针：离线读取设备上拉取的 jx_playlists.hive，列出全部键与收藏歌单状态。
// 用法：dart run tool/probe_playlists_box.dart <box文件路径>
import 'package:hive/hive.dart';
import 'dart:io';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '.dart_tool/dev_jx_playlists.hive';
  final src = File(path);
  if (!src.existsSync()) {
    stderr.writeln('box 文件不存在: $path');
    exitCode = 2;
    return;
  }
  // Hive.openBox 只接受目录作为 path，文件名由 box name 决定
  final temp = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}probe_box_${DateTime.now().millisecondsSinceEpoch}.hive');
  await temp.writeAsBytes(await src.readAsBytes());
  Hive.init(Directory.systemTemp.path);
  final box = await Hive.openBox<Map>(temp.uri.pathSegments.last.replaceAll('.hive', ''));
  print('=== box keys (${box.length}) ===');
  for (final k in box.keys) {
    final v = box.get(k);
    final vs = v == null ? 'null' : (v.toString().length > 90 ? '${v.toString().substring(0, 90)}…' : v.toString());
    print('  $k => $vs');
  }
  await box.close();
  await temp.delete();
}
