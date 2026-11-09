# music_decoder

A pure Dart library that restores NetEase Cloud Music (.ncm) and QQ Music
encrypted files into playable audio (flac/mp3/ogg/m4a/wav). It focuses on
streaming decode and keeps platform dependencies at zero, so Flutter apps can
reuse the same API.

Chinese documentation: `README-zh_CN.md`.

## Features

- Decode NetEase Cloud Music `.ncm` files back to the original audio stream.
- Decode QQ Music QMC variants (v1/v2) via tail-key extraction.
- Write tags for NCM output (title/album/artist and cover art).
- Stream-based decoding to avoid loading large files in memory.

## Install

Add the dependency:

```yaml
dependencies:
  music_decoder: ^0.1.0
```

Then run `dart pub get`.

## Usage

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

For a runnable demo, see `example/music_decoder_example.dart` and place your
files in:

- `example/music/netease_cloud_music` for `.ncm`
- `example/music/qq_music` for QMC variants (`qmcflac`, `mflac`, `mgg`, etc.)

## Notes

- QMC output is a raw audio stream; existing tags are preserved only if they are
  embedded in the encrypted file itself.
- Sample audio files are excluded from the published package; keep them local.
- Some rare QMC variants may require additional mappings in `qmc_constants.dart`.
- Newer QQ Music formats (with a `musicex` tail) may decode into corrupt FLAC
  streams due to updated encryption; see the upstream QMCDecode issue for
  details: https://github.com/gongjiehong/QMCDecode/issues/3

## Reference Projects

- ncmdump (Python): https://github.com/lissettecarlr/ncmdump
- QMCDecode (Swift): https://github.com/MatrixCD/QMCDecode
