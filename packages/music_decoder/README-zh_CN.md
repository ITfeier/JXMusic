# music_decoder

一个纯 Dart 工具库，用于将网易云音乐（`.ncm`）和 QQ 音乐加密文件
还原为可播放的音频（flac/mp3/ogg/m4a/wav）。解码过程采用流式处理，
没有平台依赖，Flutter 也可以直接集成。

## 功能特性

- 还原网易云 `.ncm` 文件为原始音频流。
- 支持 QQ 音乐 QMC v1/v2 变体（通过文件尾部 key 解密）。
- NCM 输出写入标签（标题/专辑/艺术家/封面）。
- 流式解码，避免大文件占用过多内存。

## 安装

在 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  music_decoder: ^0.1.0
```

然后执行 `dart pub get`。

## 使用示例

```dart
import 'dart:io';
import 'package:music_decoder/music_decoder.dart';

Future<void> main() async {
  final decoder = MusicDecoder();

  final ncmResult = await decoder.decodeNcm(File('song.ncm'));
  print('NCM -> ${ncmResult.outputFile.path}');

  final qmcResult = await decoder.decodeQmc(File('track.qmcflac'));
  print('QMC -> ${qmcResult.outputFile.path}');
}
```

可运行示例在 `example/music_decoder_example.dart`。请将样本文件放到：

- `example/music/netease_cloud_music`（`.ncm`）
- `example/music/qq_music`（`qmcflac`、`mflac`、`mgg` 等）

## 说明

- QMC 仅还原音频流，标签是否保留取决于原文件本身。
- 示例音频不会发布到 pub.dev，请保留在本地目录。
- 个别 QMC 扩展名可能需要在 `qmc_constants.dart` 中补充映射。
- 新版 QQ 音乐格式（尾部包含 `musicex`）因加密方式更新，可能解出损坏
  的 FLAC 音频流，详见 QMCDecode issue：https://github.com/gongjiehong/QMCDecode/issues/3

## 参考项目

- ncmdump (Python): https://github.com/lissettecarlr/ncmdump
- QMCDecode (Swift): https://github.com/MatrixCD/QMCDecode
