import 'dart:io';

import 'package:music_decoder/music_decoder.dart';

Future<void> main() async {
  final decoder = MusicDecoder();
  final scriptDir = File.fromUri(Platform.script).parent;
  final baseDir = Directory('${scriptDir.path}/music');

  final neteaseDir = Directory('${baseDir.path}/netease_cloud_music');
  final qqDir = Directory('${baseDir.path}/qq_music');

  await _decodeNetease(decoder, neteaseDir);
  await _decodeQq(decoder, qqDir);
}

Future<void> _decodeNetease(
  MusicDecoder decoder,
  Directory neteaseDir,
) async {
  if (!await neteaseDir.exists()) {
    print('Netease folder not found: ${neteaseDir.path}');
    return;
  }

  final ncmFiles = neteaseDir
      .listSync()
      .whereType<File>()
      .where((file) => _extension(file.path) == 'ncm')
      .toList();

  if (ncmFiles.isEmpty) {
    print('No .ncm files found in ${neteaseDir.path}');
    return;
  }

  for (final file in ncmFiles) {
    final result = await decoder.decodeNcm(file);
    print('Decoded ${file.path} -> ${result.outputFile.path}');
  }
}

Future<void> _decodeQq(
  MusicDecoder decoder,
  Directory qqDir,
) async {
  if (!await qqDir.exists()) {
    print('QQ folder not found: ${qqDir.path}');
    return;
  }

  final supportedQmc = QmcDecoder.supportedExtensions.toSet();
  final qmcFiles = qqDir
      .listSync()
      .whereType<File>()
      .where((file) => supportedQmc.contains(_extension(file.path)))
      .toList();

  if (qmcFiles.isEmpty) {
    print('No QMC files found in ${qqDir.path}');
    return;
  }

  for (final file in qmcFiles) {
    final result = await decoder.decodeQmc(file);
    print('Decoded ${file.path} -> ${result.outputFile.path}');
  }
}

String _extension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot == -1 || dot == path.length - 1) {
    return '';
  }
  return path.substring(dot + 1).toLowerCase();
}
