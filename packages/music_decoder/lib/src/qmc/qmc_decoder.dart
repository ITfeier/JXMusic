import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'qmc_cipher.dart';
import 'qmc_constants.dart';
import 'qmc_key_decoder.dart';

class QmcException implements Exception {
  QmcException(this.message);

  final String message;

  @override
  String toString() => 'QmcException: $message';
}

class QmcDecodeResult {
  const QmcDecodeResult({required this.outputFile, required this.format});

  final File outputFile;
  final String format;
}

class QmcDecoder {
  static const int bufferSize = 16384;

  static final List<String> supportedExtensions =
      List.unmodifiable(qmcExtensionMap.keys);

  Future<QmcDecodeResult> decodeFile(
    File input, {
    File? output,
  }) async {
    if (!await input.exists()) {
      throw QmcException('Input file not found: ${input.path}');
    }

    final fileExtension = _fileExtension(input.path);
    final info = qmcExtensionMap[fileExtension];
    if (info == null) {
      throw QmcException('Unsupported QMC extension: $fileExtension');
    }

    final fileLength = await input.length();
    if (fileLength < 4) {
      throw QmcException('File is too small to decode.');
    }

    final raf = await input.open();
    try {
      final keySearch = await _searchKey(raf, fileLength, info);
      final outputFile = output ??
          File(_defaultOutputPath(input.path, info.ext));
      if (outputFile.path == input.path) {
        throw QmcException('Output path must differ from input path.');
      }

      final outputRaf = await outputFile.open(mode: FileMode.write);
      try {
        await raf.setPosition(0);
        var offset = 0;
        var remaining = keySearch.audioSize;
        while (remaining > 0) {
          final chunk =
              await raf.read(remaining > bufferSize ? bufferSize : remaining);
          if (chunk.isEmpty) {
            throw QmcException('Unexpected end of file while decoding audio.');
          }
          final decoded = keySearch.cipher.decrypt(chunk, offset);
          await outputRaf.writeFrom(decoded);
          offset += chunk.length;
          remaining -= chunk.length;
        }
      } finally {
        await outputRaf.close();
      }

      return QmcDecodeResult(outputFile: outputFile, format: info.ext);
    } finally {
      await raf.close();
    }
  }
}

class _KeySearchResult {
  const _KeySearchResult({required this.cipher, required this.audioSize});

  final QmcCipher cipher;
  final int audioSize;
}

Future<_KeySearchResult> _searchKey(
  RandomAccessFile raf,
  int fileLength,
  QmcExtensionInfo info,
) async {
  if (fileLength >= 8) {
    await raf.setPosition(fileLength - 8);
    final tail = await raf.read(8);
    if (_bytesEqual(tail, _musicExMagic)) {
      if (info.ext != 'flac') {
        throw QmcException('musicex format is only supported for flac files.');
      }
      final xorKey = await _deriveMusicExKey(raf, _flacHeader);
      return _KeySearchResult(
        cipher: QmXorCipher(xorKey),
        audioSize: fileLength,
      );
    }
  }

  await raf.setPosition(fileLength - 4);
  final lastFour = await raf.read(4);
  if (lastFour.length != 4) {
    throw QmcException('Unable to read file footer.');
  }

  final lastFourText = ascii.decode(lastFour, allowInvalid: true);
  final commaCode = ','.codeUnitAt(0);

  if (lastFourText == 'QTag') {
    await raf.setPosition(fileLength - 8);
    final sizeBuffer = await raf.read(4);
    if (sizeBuffer.length != 4) {
      throw QmcException('Unable to read QTag key size.');
    }
    final keySize = _readUint32Be(sizeBuffer);
    final audioSize = fileLength - keySize - 8;
    if (audioSize <= 0) {
      throw QmcException('Invalid QTag key size.');
    }
    await raf.setPosition(audioSize);
    final rawKey = await raf.read(keySize);
    if (rawKey.length != keySize) {
      throw QmcException('Unable to read QTag key.');
    }
    final endIndex = rawKey.indexOf(commaCode);
    if (endIndex == -1) {
      throw QmcException('Failed to locate QTag key terminator.');
    }
    final cipher = _buildCipher(rawKey.sublist(0, endIndex));
    return _KeySearchResult(cipher: cipher, audioSize: audioSize);
  }

  final keySize = _readUint32Le(lastFour);
  if (keySize < 0x300) {
    final audioSize = fileLength - keySize - 4;
    if (audioSize <= 0) {
      throw QmcException('Invalid key size in QMC footer.');
    }
    await raf.setPosition(audioSize);
    final rawKey = await raf.read(keySize);
    if (rawKey.length != keySize) {
      throw QmcException('Unable to read key data.');
    }
    final cipher = _buildCipher(rawKey);
    return _KeySearchResult(cipher: cipher, audioSize: audioSize);
  }

  return _KeySearchResult(
    cipher: QmStaticCipher(qmcPrivateKey256),
    audioSize: fileLength,
  );
}

QmcCipher _buildCipher(Uint8List keyBuffer) {
  final decoder = QmcKeyDecoder();
  final decodedKey = decoder.deriveKey(keyBuffer);
  if (decodedKey.length > 300) {
    return QmRc4Cipher(decodedKey);
  }
  return QmMapCipher(decodedKey);
}

String _defaultOutputPath(String inputPath, String extension) {
  final dot = inputPath.lastIndexOf('.');
  final base = dot == -1 ? inputPath : inputPath.substring(0, dot);
  return '$base.$extension';
}

String _fileExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot == -1 || dot == path.length - 1) {
    return '';
  }
  return path.substring(dot + 1).toLowerCase();
}

int _readUint32Le(Uint8List bytes) {
  return bytes[0] |
      (bytes[1] << 8) |
      (bytes[2] << 16) |
      (bytes[3] << 24);
}

int _readUint32Be(Uint8List bytes) {
  return (bytes[0] << 24) |
      (bytes[1] << 16) |
      (bytes[2] << 8) |
      bytes[3];
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

final Uint8List _musicExMagic = Uint8List.fromList(
  [0x6D, 0x75, 0x73, 0x69, 0x63, 0x65, 0x78, 0x00],
);

final Uint8List _flacHeader = Uint8List.fromList(
  [0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22],
);

Future<Uint8List> _deriveMusicExKey(
  RandomAccessFile raf,
  Uint8List expectedHeader,
) async {
  await raf.setPosition(0);
  final header = await raf.read(8);
  if (header.length != 8) {
    throw QmcException('Unable to read file header for musicex.');
  }
  final key = Uint8List(8);
  for (var i = 0; i < 8; i++) {
    key[i] = header[i] ^ expectedHeader[i];
  }
  return key;
}
