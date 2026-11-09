import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

class QmcKeyDecoderException implements Exception {
  QmcKeyDecoderException(this.message);

  final String message;

  @override
  String toString() => 'QmcKeyDecoderException: $message';
}

class QmcKeyDecoder {
  static const int _saltLength = 2;
  static const int _zeroLength = 7;

  Uint8List deriveKey(Uint8List rawKey) {
    final base64Text =
        ascii.decode(rawKey, allowInvalid: true).trim();
    if (base64Text.isEmpty) {
      throw QmcKeyDecoderException('Base64 key is empty.');
    }

    Uint8List base64Decoded;
    try {
      base64Decoded = Uint8List.fromList(base64.decode(base64Text));
    } on FormatException catch (error) {
      throw QmcKeyDecoderException('Invalid base64 key: ${error.message}');
    }

    if (base64Decoded.length < 16) {
      throw QmcKeyDecoderException('Base64 key is too short.');
    }

    final simpleKey = _simpleMakeKey(seed: 106, length: 8);
    final teaKey = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      teaKey[i << 1] = simpleKey[i];
      teaKey[(i << 1) + 1] = base64Decoded[i];
    }

    final inBuffer = base64Decoded.sublist(8);
    final subBuffer = _decryptTencentTea(inBuffer, teaKey);

    final output = Uint8List(8 + subBuffer.length);
    output.setRange(0, 8, base64Decoded.sublist(0, 8));
    output.setRange(8, output.length, subBuffer);
    return output;
  }

  Uint8List _simpleMakeKey({required int seed, required int length}) {
    final result = Uint8List(length);
    for (var i = 0; i < length; i++) {
      final value = tan(seed + i * 0.1).abs() * 100;
      result[i] = value.floor() & 0xFF;
    }
    return result;
  }

  Uint8List _decryptTencentTea(Uint8List inBuffer, Uint8List key) {
    if (inBuffer.length % 8 != 0) {
      throw QmcKeyDecoderException('Input length must be multiple of 8.');
    }
    if (inBuffer.length < 16) {
      throw QmcKeyDecoderException('Input buffer is too small.');
    }

    final teaCipher = _TeaCipher(key, rounds: 32);
    var tempBuffer = teaCipher.decryptBlock(inBuffer.sublist(0, 8));

    final paddingLength = tempBuffer[0] & 0x7;
    final outputLength =
        inBuffer.length - 1 - paddingLength - _saltLength - _zeroLength;

    if (paddingLength + _saltLength != 8) {
      throw QmcKeyDecoderException('Invalid padding length.');
    }
    if (outputLength < 0) {
      throw QmcKeyDecoderException('Invalid output length.');
    }

    final outputBuffer = Uint8List(outputLength);

    var ivPrevious = Uint8List(8);
    var ivCurrent = inBuffer.sublist(0, 8);
    var inBufferPosition = 8;
    var tempIndex = 1 + paddingLength;

    void cryptBlock() {
      ivPrevious = ivCurrent;
      ivCurrent = inBuffer.sublist(inBufferPosition, inBufferPosition + 8);
      for (var j = 0; j < 8; j++) {
        tempBuffer[j] ^= ivCurrent[j];
      }
      tempBuffer = teaCipher.decryptBlock(tempBuffer);
      inBufferPosition += 8;
      tempIndex = 0;
    }

    var saltIndex = 1;
    while (saltIndex <= _saltLength) {
      if (tempIndex < 8) {
        tempIndex += 1;
        saltIndex += 1;
      } else {
        cryptBlock();
      }
    }

    var outputIndex = 0;
    while (outputIndex < outputLength) {
      if (tempIndex < 8) {
        outputBuffer[outputIndex] =
            tempBuffer[tempIndex] ^ ivPrevious[tempIndex];
        outputIndex += 1;
        tempIndex += 1;
      } else {
        cryptBlock();
      }
    }

    var zeroIndex = 0;
    while (zeroIndex < _zeroLength) {
      if (tempIndex < 8) {
        if (tempBuffer[tempIndex] != ivPrevious[tempIndex]) {
          throw QmcKeyDecoderException('Zero check failed.');
        }
        tempIndex += 1;
        zeroIndex += 1;
      } else {
        cryptBlock();
      }
    }

    return outputBuffer;
  }
}

class _TeaCipher {
  _TeaCipher(Uint8List key, {int rounds = 64}) {
    if (key.length != 16) {
      throw QmcKeyDecoderException('TEA key length must be 16 bytes.');
    }
    if (rounds.isOdd) {
      throw QmcKeyDecoderException('TEA rounds must be even.');
    }

    _rounds = rounds;
    _key0 = _readUint32Be(key, 0);
    _key1 = _readUint32Be(key, 4);
    _key2 = _readUint32Be(key, 8);
    _key3 = _readUint32Be(key, 12);
  }

  static const int _delta = 0x9E3779B9;
  late final int _rounds;
  late final int _key0;
  late final int _key1;
  late final int _key2;
  late final int _key3;

  Uint8List decryptBlock(Uint8List block) {
    if (block.length < 8) {
      throw QmcKeyDecoderException('TEA block must be 8 bytes.');
    }
    var v0 = _readUint32Be(block, 0);
    var v1 = _readUint32Be(block, 4);
    var sum = (_delta * (_rounds ~/ 2)) & 0xFFFFFFFF;

    for (var i = 0; i < _rounds ~/ 2; i++) {
      v1 = (v1 - (((v0 << 4) + _key2) ^ (v0 + sum) ^ ((v0 >> 5) + _key3))) &
          0xFFFFFFFF;
      v0 = (v0 - (((v1 << 4) + _key0) ^ (v1 + sum) ^ ((v1 >> 5) + _key1))) &
          0xFFFFFFFF;
      sum = (sum - _delta) & 0xFFFFFFFF;
    }

    final out = Uint8List(8);
    _writeUint32Be(out, 0, v0);
    _writeUint32Be(out, 4, v1);
    return out;
  }
}

int _readUint32Be(Uint8List data, int offset) {
  return (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];
}

void _writeUint32Be(Uint8List data, int offset, int value) {
  data[offset] = (value >> 24) & 0xFF;
  data[offset + 1] = (value >> 16) & 0xFF;
  data[offset + 2] = (value >> 8) & 0xFF;
  data[offset + 3] = value & 0xFF;
}
