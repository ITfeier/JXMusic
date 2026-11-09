import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class NcmException implements Exception {
  NcmException(this.message);

  final String message;

  @override
  String toString() => 'NcmException: $message';
}

class DecodeResult {
  const DecodeResult({required this.outputFile, required this.metadata});

  final File outputFile;
  final NcmMetadata metadata;
}

class NcmMetadata {
  const NcmMetadata({
    required this.format,
    required this.title,
    required this.album,
    required this.artists,
    this.comment,
  });

  final String format;
  final String title;
  final String album;
  final List<String> artists;
  final String? comment;

  factory NcmMetadata.fromJson(Map<String, dynamic> json, {String? comment}) {
    final format = (_readString(json['format']) ?? 'mp3').toLowerCase();
    final title = _readString(json['musicName']) ??
        _readString(json['title']) ??
        'Unknown Title';
    final album = _readString(json['album']) ?? 'Unknown Album';
    final artists = _parseArtists(json['artist']) ??
        _parseArtists(json['artists']) ??
        <String>['Unknown Artist'];

    return NcmMetadata(
      format: format,
      title: title,
      album: album,
      artists: artists.isEmpty ? <String>['Unknown Artist'] : artists,
      comment: comment,
    );
  }
}

class NcmDecoder {
  static const int bufferSize = 16384;

  Future<DecodeResult> decodeFile(
    File input, {
    File? output,
    bool writeTags = true,
  }) async {
    if (!await input.exists()) {
      throw NcmException('Input file not found: ${input.path}');
    }

    final inputRaf = await input.open();
    try {
      final parsed = await _parseNcm(inputRaf, await input.length());
      final outputFile =
          output ?? File(_defaultOutputPath(input.path, parsed.metadata.format));
      if (outputFile.path == input.path) {
        throw NcmException('Output path must differ from input path.');
      }

      final outputRaf = await outputFile.open(mode: FileMode.write);
      try {
        await inputRaf.setPosition(parsed.audioOffset);
        while (true) {
          final chunk = await inputRaf.read(bufferSize);
          if (chunk.isEmpty) {
            break;
          }
          final decoded = _xorWithKey(chunk, parsed.keyStream);
          await outputRaf.writeFrom(decoded);
        }
      } finally {
        await outputRaf.close();
      }

      if (writeTags) {
        if (parsed.metadata.format.toLowerCase() == 'flac') {
          await _FlacTagWriter.write(
            outputFile,
            parsed.metadata,
            parsed.imageData,
          );
        } else if (parsed.metadata.format.toLowerCase() == 'mp3') {
          await _Mp3TagWriter.write(
            outputFile,
            parsed.metadata,
            parsed.imageData,
          );
        }
      }

      return DecodeResult(outputFile: outputFile, metadata: parsed.metadata);
    } finally {
      await inputRaf.close();
    }
  }
}

class _ParsedNcm {
  const _ParsedNcm({
    required this.keyStream,
    required this.metadata,
    required this.audioOffset,
    this.imageData,
  });

  final Uint8List keyStream;
  final NcmMetadata metadata;
  final int audioOffset;
  final Uint8List? imageData;
}

Future<_ParsedNcm> _parseNcm(RandomAccessFile raf, int fileLength) async {
  final header = await raf.read(8);
  if (header.length != 8) {
    throw NcmException('Unexpected end of file while reading header.');
  }
  if (!_bytesEqual(header, _ncmMagic)) {
    throw NcmException('Invalid NCM header.');
  }

  await raf.setPosition(await raf.position() + 2);

  final keyLength = _readUint32Le(await raf.read(4));
  final rawKey = await raf.read(keyLength);
  if (rawKey.length != keyLength) {
    throw NcmException('Unexpected end of file while reading key data.');
  }
  final keyData = _xorWithByte(rawKey, 0x64);

  final decryptedKey = _aesEcbDecrypt(_coreKey, keyData);
  final unpaddedKey = _pkcs7Unpad(decryptedKey);
  if (unpaddedKey.length < 17) {
    throw NcmException('Decrypted key data is too short.');
  }
  final keyStream = _generateKeyStream(unpaddedKey.sublist(17));

  final metaLength = _readUint32Le(await raf.read(4));
  Map<String, dynamic> metaJson;
  if (metaLength > 0) {
    final metaBuffer = await raf.read(metaLength);
    if (metaBuffer.length != metaLength) {
      throw NcmException('Unexpected end of file while reading metadata.');
    }
    final metaRaw = _xorWithByte(metaBuffer, 0x63);
    if (metaRaw.length < 22) {
      throw NcmException('Metadata block is too short.');
    }
    final metaBase64 = metaRaw.sublist(22);
    final metaBase64Text =
        utf8.decode(metaBase64, allowMalformed: true).trim();
    final metaDecoded = base64.decode(metaBase64Text);
    final metaDecrypted = _aesEcbDecrypt(_metaKey, metaDecoded);
    final metaUnpadded = _pkcs7Unpad(metaDecrypted);
    final metaText = utf8.decode(metaUnpadded);
    final jsonText = metaText.length >= 6 ? metaText.substring(6) : '{}';
    metaJson = json.decode(jsonText) as Map<String, dynamic>;
  } else {
    metaJson = <String, dynamic>{
      'format': fileLength > 1024 * 1024 * 16 ? 'flac' : 'mp3',
    };
  }

  final metadata = NcmMetadata.fromJson(metaJson);

  await raf.setPosition(await raf.position() + 5);
  final imageSpace = _readUint32Le(await raf.read(4));
  final imageSize = _readUint32Le(await raf.read(4));
  Uint8List? imageData;
  if (imageSize > 0) {
    imageData = await raf.read(imageSize);
    if (imageData.length != imageSize) {
      throw NcmException('Unexpected end of file while reading cover art.');
    }
  }
  if (imageSpace > imageSize) {
    await raf.setPosition(await raf.position() + (imageSpace - imageSize));
  }

  final audioOffset = await raf.position();

  return _ParsedNcm(
    keyStream: keyStream,
    metadata: metadata,
    audioOffset: audioOffset,
    imageData: imageData,
  );
}

class _Mp3TagWriter {
  static Future<void> write(
    File file,
    NcmMetadata metadata,
    Uint8List? imageData,
  ) async {
    final frames = <Uint8List>[];
    frames.addAll(_buildTextFrames(metadata));

    if (metadata.comment != null && metadata.comment!.trim().isNotEmpty) {
      frames.add(_buildCommentFrame(metadata.comment!));
    }

    if (imageData != null && imageData.isNotEmpty) {
      frames.add(_buildApicFrame(imageData));
    }

    if (frames.isEmpty) {
      return;
    }

    final tagData = BytesBuilder();
    for (final frame in frames) {
      tagData.add(frame);
    }
    final tagBytes = tagData.toBytes();

    final header = BytesBuilder();
    header.add(ascii.encode('ID3'));
    header.add([0x03, 0x00, 0x00]);
    header.add(_encodeSynchsafe(tagBytes.length));

    final tempFile = File('${file.path}.tmp');
    final input = await file.open();
    final output = await tempFile.open(mode: FileMode.write);

    try {
      final audioStart = await _skipExistingId3(input);
      await output.writeFrom(header.toBytes());
      await output.writeFrom(tagBytes);
      await input.setPosition(audioStart);
      while (true) {
        final chunk = await input.read(NcmDecoder.bufferSize);
        if (chunk.isEmpty) {
          break;
        }
        await output.writeFrom(chunk);
      }
    } finally {
      await input.close();
      await output.close();
    }

    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  static List<Uint8List> _buildTextFrames(NcmMetadata metadata) {
    final frames = <Uint8List>[];
    frames.add(_buildTextFrame('TIT2', metadata.title));
    frames.add(_buildTextFrame('TALB', metadata.album));
    frames.add(_buildTextFrame('TPE1', metadata.artists.join('/')));
    return frames.where((frame) => frame.isNotEmpty).toList();
  }

  static Uint8List _buildTextFrame(String id, String value) {
    if (value.trim().isEmpty) {
      return Uint8List(0);
    }
    final data = BytesBuilder();
    data.add([0x01]);
    data.add(_encodeUtf16Le(value));
    return _buildFrame(id, data.toBytes());
  }

  static Uint8List _buildCommentFrame(String comment) {
    final data = BytesBuilder();
    data.add([0x01]);
    data.add(ascii.encode('eng'));
    data.add(_encodeUtf16Le(''));
    data.add([0x00, 0x00]);
    data.add(_encodeUtf16Le(comment));
    return _buildFrame('COMM', data.toBytes());
  }

  static Uint8List _buildApicFrame(Uint8List imageData) {
    final data = BytesBuilder();
    data.add([0x01]);
    data.add(ascii.encode(_imageMime(imageData)));
    data.add([0x00]);
    data.add([0x03]);
    data.add(_encodeUtf16Le(''));
    data.add([0x00, 0x00]);
    data.add(imageData);
    return _buildFrame('APIC', data.toBytes());
  }

  static Uint8List _buildFrame(String id, Uint8List data) {
    final frame = BytesBuilder();
    frame.add(ascii.encode(id));
    frame.add(_uint32Be(data.length));
    frame.add([0x00, 0x00]);
    frame.add(data);
    return frame.toBytes();
  }

  static Future<int> _skipExistingId3(RandomAccessFile raf) async {
    final start = await raf.position();
    final header = await raf.read(10);
    if (header.length < 10) {
      await raf.setPosition(start);
      return start;
    }
    if (ascii.decode(header.sublist(0, 3), allowInvalid: true) != 'ID3') {
      await raf.setPosition(start);
      return start;
    }
    final size = _decodeSynchsafe(header.sublist(6, 10));
    return start + 10 + size;
  }
}

class _FlacTagWriter {
  static Future<void> write(
    File file,
    NcmMetadata metadata,
    Uint8List? imageData,
  ) async {
    final input = await file.open();
    final header = await input.read(4);
    if (!_bytesEqual(header, _flacMagic)) {
      await input.close();
      throw NcmException('Invalid FLAC header.');
    }

    Uint8List? streamInfo;
    bool isLast = false;
    while (!isLast) {
      final blockHeader = await input.read(4);
      if (blockHeader.length < 4) {
        await input.close();
        throw NcmException('Unexpected end of FLAC metadata.');
      }
      final typeAndLast = blockHeader[0];
      isLast = (typeAndLast & 0x80) != 0;
      final blockType = typeAndLast & 0x7F;
      final length =
          (blockHeader[1] << 16) | (blockHeader[2] << 8) | blockHeader[3];
      final data = await input.read(length);
      if (data.length != length) {
        await input.close();
        throw NcmException('Unexpected end of FLAC metadata block.');
      }
      if (blockType == 0) {
        streamInfo = data;
      }
    }

    if (streamInfo == null) {
      await input.close();
      throw NcmException('FLAC STREAMINFO block not found.');
    }

    final audioOffset = await input.position();

    final hasPicture = imageData != null && imageData.isNotEmpty;
    final vorbisData = _buildVorbisComment(metadata);
    final vorbisBlock =
        _buildFlacBlock(4, vorbisData, isLast: !hasPicture);

    Uint8List? pictureBlock;
    if (hasPicture) {
      final pictureData = _buildPictureBlock(imageData);
      pictureBlock = _buildFlacBlock(6, pictureData, isLast: true);
    }

    final streamInfoBlock =
        _buildFlacBlock(0, streamInfo, isLast: false);

    final tempFile = File('${file.path}.tmp');
    final output = await tempFile.open(mode: FileMode.write);
    try {
      await output.writeFrom(_flacMagic);
      await output.writeFrom(streamInfoBlock);
      await output.writeFrom(vorbisBlock);
      if (pictureBlock != null) {
        await output.writeFrom(pictureBlock);
      }

      await input.setPosition(audioOffset);
      while (true) {
        final chunk = await input.read(NcmDecoder.bufferSize);
        if (chunk.isEmpty) {
          break;
        }
        await output.writeFrom(chunk);
      }
    } finally {
      await input.close();
      await output.close();
    }

    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  static Uint8List _buildVorbisComment(NcmMetadata metadata) {
    final comments = <String>[];
    comments.add('TITLE=${metadata.title}');
    comments.add('ALBUM=${metadata.album}');
    comments.add('ARTIST=${metadata.artists.join('/')}');
    if (metadata.comment != null && metadata.comment!.trim().isNotEmpty) {
      comments.add('COMMENT=${metadata.comment}');
    }

    final vendor = utf8.encode('music_decoder');
    final builder = BytesBuilder();
    builder.add(_uint32Le(vendor.length));
    builder.add(vendor);
    builder.add(_uint32Le(comments.length));
    for (final comment in comments) {
      final bytes = utf8.encode(comment);
      builder.add(_uint32Le(bytes.length));
      builder.add(bytes);
    }
    return builder.toBytes();
  }

  static Uint8List _buildPictureBlock(Uint8List imageData) {
    final mime = _imageMime(imageData);
    final description = utf8.encode('');
    final imageInfo = _readImageInfo(imageData);

    final builder = BytesBuilder();
    builder.add(_uint32Be(3));
    builder.add(_uint32Be(mime.length));
    builder.add(ascii.encode(mime));
    builder.add(_uint32Be(description.length));
    builder.add(description);
    builder.add(_uint32Be(imageInfo.width));
    builder.add(_uint32Be(imageInfo.height));
    builder.add(_uint32Be(imageInfo.depth));
    builder.add(_uint32Be(imageInfo.colors));
    builder.add(_uint32Be(imageData.length));
    builder.add(imageData);
    return builder.toBytes();
  }

  static Uint8List _buildFlacBlock(
    int type,
    Uint8List data, {
    required bool isLast,
  }) {
    final builder = BytesBuilder();
    builder.add([((isLast ? 0x80 : 0x00) | type) & 0xFF]);
    builder.add([
      (data.length >> 16) & 0xFF,
      (data.length >> 8) & 0xFF,
      data.length & 0xFF,
    ]);
    builder.add(data);
    return builder.toBytes();
  }
}

class _ImageInfo {
  const _ImageInfo({
    required this.width,
    required this.height,
    required this.depth,
    required this.colors,
  });

  final int width;
  final int height;
  final int depth;
  final int colors;
}

_ImageInfo _readImageInfo(Uint8List imageData) {
  if (_looksLikePng(imageData)) {
    return _readPngInfo(imageData);
  }
  if (_looksLikeJpeg(imageData)) {
    return _readJpegInfo(imageData);
  }
  return const _ImageInfo(width: 0, height: 0, depth: 0, colors: 0);
}

_ImageInfo _readPngInfo(Uint8List imageData) {
  if (imageData.length < 29) {
    return const _ImageInfo(width: 0, height: 0, depth: 0, colors: 0);
  }
  final width = _readUint32Be(imageData.sublist(16, 20));
  final height = _readUint32Be(imageData.sublist(20, 24));
  final bitDepth = imageData[24];
  final colorType = imageData[25];
  final channels = switch (colorType) {
    0 => 1,
    2 => 3,
    3 => 1,
    4 => 2,
    6 => 4,
    _ => 0,
  };
  final depth = channels == 0 ? 0 : bitDepth * channels;
  return _ImageInfo(width: width, height: height, depth: depth, colors: 0);
}

_ImageInfo _readJpegInfo(Uint8List imageData) {
  int index = 2;
  while (index + 9 < imageData.length) {
    if (imageData[index] != 0xFF) {
      index++;
      continue;
    }
    while (index < imageData.length && imageData[index] == 0xFF) {
      index++;
    }
    if (index >= imageData.length) {
      break;
    }
    final marker = imageData[index];
    index++;
    if (marker == 0xD8 || marker == 0xD9) {
      continue;
    }
    if (index + 1 >= imageData.length) {
      break;
    }
    final length = (imageData[index] << 8) | imageData[index + 1];
    if (length < 2 || index + length > imageData.length) {
      break;
    }
    if (marker == 0xC0 || marker == 0xC2) {
      if (index + 7 >= imageData.length) {
        break;
      }
      final precision = imageData[index + 2];
      final height = (imageData[index + 3] << 8) | imageData[index + 4];
      final width = (imageData[index + 5] << 8) | imageData[index + 6];
      final components = imageData[index + 7];
      final depth = precision * components;
      return _ImageInfo(width: width, height: height, depth: depth, colors: 0);
    }
    index += length;
  }
  return const _ImageInfo(width: 0, height: 0, depth: 0, colors: 0);
}

Uint8List _generateKeyStream(Uint8List keyData) {
  final keyLength = keyData.length;
  if (keyLength == 0) {
    throw NcmException('Key data is empty.');
  }
  final s = List<int>.generate(256, (index) => index);
  int j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + keyData[i % keyLength]) & 0xFF;
    final temp = s[i];
    s[i] = s[j];
    s[j] = temp;
  }

  final stream = List<int>.generate(256, (i) {
    final idx = (s[i] + s[(i + s[i]) & 0xFF]) & 0xFF;
    return s[idx];
  });

  final output = Uint8List(256 * 64);
  for (var i = 0; i < 256; i++) {
    output[i] = stream[(i + 1) % 256];
  }
  final base = Uint8List.fromList(output.sublist(0, 256));
  for (var block = 1; block < 64; block++) {
    output.setRange(block * 256, (block + 1) * 256, base);
  }
  return output;
}

Uint8List _aesEcbDecrypt(Uint8List key, Uint8List data) {
  if (data.isEmpty || data.length % 16 != 0) {
    throw NcmException('AES input is not aligned to 16 bytes.');
  }
  final cipher = ECBBlockCipher(AESEngine());
  cipher.init(false, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var offset = 0; offset < data.length; offset += cipher.blockSize) {
    cipher.processBlock(data, offset, out, offset);
  }
  return out;
}

Uint8List _pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) {
    throw NcmException('PKCS7 unpad failed: empty data.');
  }
  final pad = data.last;
  if (pad == 0 || pad > 16 || pad > data.length) {
    throw NcmException('PKCS7 unpad failed: invalid padding.');
  }
  for (var i = data.length - pad; i < data.length; i++) {
    if (data[i] != pad) {
      throw NcmException('PKCS7 unpad failed: invalid padding.');
    }
  }
  return data.sublist(0, data.length - pad);
}

Uint8List _xorWithKey(Uint8List data, Uint8List key) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = data[i] ^ key[i % key.length];
  }
  return out;
}

Uint8List _xorWithByte(Uint8List data, int value) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = data[i] ^ value;
  }
  return out;
}

Uint8List _encodeSynchsafe(int value) {
  return Uint8List.fromList([
    (value >> 21) & 0x7F,
    (value >> 14) & 0x7F,
    (value >> 7) & 0x7F,
    value & 0x7F,
  ]);
}

int _decodeSynchsafe(Uint8List bytes) {
  if (bytes.length != 4) {
    return 0;
  }
  return (bytes[0] << 21) | (bytes[1] << 14) | (bytes[2] << 7) | bytes[3];
}

Uint8List _encodeUtf16Le(String value) {
  final units = value.codeUnits;
  final out = BytesBuilder();
  out.add([0xFF, 0xFE]);
  for (final unit in units) {
    out.add([unit & 0xFF, (unit >> 8) & 0xFF]);
  }
  return out.toBytes();
}

Uint8List _uint32Le(int value) {
  return Uint8List.fromList([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);
}

Uint8List _uint32Be(int value) {
  return Uint8List.fromList([
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);
}

int _readUint32Le(Uint8List bytes) {
  if (bytes.length < 4) {
    return 0;
  }
  return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
}

int _readUint32Be(Uint8List bytes) {
  if (bytes.length < 4) {
    return 0;
  }
  return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

String? _readString(Object? value) {
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  return null;
}

List<String>? _parseArtists(Object? value) {
  if (value is List) {
    final artists = <String>[];
    for (final entry in value) {
      if (entry is List && entry.isNotEmpty) {
        artists.add(entry.first.toString());
      } else if (entry is String && entry.trim().isNotEmpty) {
        artists.add(entry);
      }
    }
    return artists;
  }
  return null;
}

String _defaultOutputPath(String inputPath, String format) {
  final dot = inputPath.lastIndexOf('.');
  final base = dot == -1 ? inputPath : inputPath.substring(0, dot);
  return '$base.$format';
}

String _imageMime(Uint8List data) {
  if (_looksLikePng(data)) {
    return 'image/png';
  }
  if (_looksLikeJpeg(data)) {
    return 'image/jpeg';
  }
  return 'application/octet-stream';
}

bool _looksLikePng(Uint8List data) {
  return data.length >= 8 &&
      data[0] == 0x89 &&
      data[1] == 0x50 &&
      data[2] == 0x4E &&
      data[3] == 0x47;
}

bool _looksLikeJpeg(Uint8List data) {
  return data.length >= 2 && data[0] == 0xFF && data[1] == 0xD8;
}

final Uint8List _ncmMagic = Uint8List.fromList(
  [0x43, 0x54, 0x45, 0x4E, 0x46, 0x44, 0x41, 0x4D],
);
final Uint8List _flacMagic = Uint8List.fromList([0x66, 0x4C, 0x61, 0x43]);

final Uint8List _coreKey = _hexToBytes('687A4852416D736F356B496E62617857');
final Uint8List _metaKey = _hexToBytes('2331346C6A6B5F215C5D2630553C2728');

Uint8List _hexToBytes(String hex) {
  final clean = hex.trim();
  if (clean.length % 2 != 0) {
    throw NcmException('Invalid hex string length.');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < clean.length; i += 2) {
    final byte = int.parse(clean.substring(i, i + 2), radix: 16);
    out[i ~/ 2] = byte;
  }
  return out;
}
