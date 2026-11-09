import 'dart:math';
import 'dart:typed_data';

class QmcCipherException implements Exception {
  QmcCipherException(this.message);

  final String message;

  @override
  String toString() => 'QmcCipherException: $message';
}

abstract class QmcCipher {
  Uint8List decrypt(Uint8List data, int offset);
}

class QmXorCipher implements QmcCipher {
  QmXorCipher(List<int> originKey)
      : key = Uint8List.fromList(originKey) {
    if (key.isEmpty) {
      throw QmcCipherException('Origin key is empty.');
    }
  }

  final Uint8List key;

  @override
  Uint8List decrypt(Uint8List data, int offset) {
    final output = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      output[i] = data[i] ^ key[(offset + i) % key.length];
    }
    return output;
  }
}

class QmStaticCipher implements QmcCipher {
  QmStaticCipher(List<int> originKey)
      : key = Uint8List.fromList(originKey) {
    if (key.isEmpty) {
      throw QmcCipherException('Origin key is empty.');
    }
  }

  final Uint8List key;

  @override
  Uint8List decrypt(Uint8List data, int offset) {
    final output = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      output[i] = data[i] ^ _getMask(offset + i);
    }
    return output;
  }

  int _getMask(int offset) {
    final temp = offset > 0x7FFF ? offset % 0x7FFF : offset;
    final index = (temp * temp + 27) & 0xFF;
    return key[index];
  }
}

class QmMapCipher implements QmcCipher {
  QmMapCipher(List<int> originKey)
      : key = Uint8List.fromList(originKey) {
    if (key.isEmpty) {
      throw QmcCipherException('Origin key is empty.');
    }
  }

  final Uint8List key;

  @override
  Uint8List decrypt(Uint8List data, int offset) {
    final output = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      output[i] = data[i] ^ _getMask(offset + i);
    }
    return output;
  }

  int _getMask(int offset) {
    final temp = offset > 0x7FFF ? offset % 0x7FFF : offset;
    final index = (temp * temp + 71214) & 0xFF;
    return _rotate(key[index], index & 0x7);
  }

  int _rotate(int value, int bits) {
    final rotate = (bits + 4) % 8;
    final left = (value << rotate) & 0xFF;
    final right = (value >> rotate) & 0xFF;
    return (left | right) & 0xFF;
  }
}

class QmRc4Cipher implements QmcCipher {
  QmRc4Cipher(List<int> originKey)
      : originKey = Uint8List.fromList(originKey) {
    if (this.originKey.isEmpty) {
      throw QmcCipherException('Origin key is empty.');
    }

    originKeyLength = this.originKey.length;

    final seedBox = Uint8List(originKeyLength);
    for (var i = 0; i < originKeyLength; i++) {
      seedBox[i] = i & 0xFF;
    }

    var tempIndex = 0;
    for (var i = 0; i < originKeyLength; i++) {
      tempIndex =
          (seedBox[i] + tempIndex + this.originKey[i % originKeyLength]) %
              originKeyLength;
      final temp = seedBox[i];
      seedBox[i] = seedBox[tempIndex];
      seedBox[tempIndex] = temp;
    }
    this.seedBox = seedBox;

    var hash = 1;
    for (var i = 0; i < originKeyLength; i++) {
      final value = this.originKey[i];
      if (value == 0) {
        continue;
      }
      final nextHash = (hash * value) & 0xFFFFFFFF;
      if (nextHash == 0 || nextHash <= hash) {
        break;
      }
      hash = nextHash;
    }
    hashValue = hash;
  }

  static const int firstSegmentSize = 0x80;
  static const int segmentSize = 0x1400;

  final Uint8List originKey;
  late final int originKeyLength;
  late final Uint8List seedBox;
  late final int hashValue;

  @override
  Uint8List decrypt(Uint8List data, int offset) {
    final result = Uint8List.fromList(data);
    var toProcess = result.length;
    var processed = 0;
    var newOffset = offset;

    bool postProcessed(int length) {
      toProcess -= length;
      processed += length;
      newOffset += length;
      return toProcess == 0;
    }

    if (newOffset < firstSegmentSize) {
      final processLength = min(result.length, firstSegmentSize - newOffset);
      _encodeFirstSegment(result, processed, processLength, newOffset);
      if (postProcessed(processLength)) {
        return result;
      }
    }

    if (newOffset % segmentSize != 0) {
      final processLength = min(segmentSize - (newOffset % segmentSize), toProcess);
      _encodeAllSegment(result, processed, processLength, newOffset);
      if (postProcessed(processLength)) {
        return result;
      }
    }

    while (toProcess > segmentSize) {
      _encodeAllSegment(result, processed, segmentSize, newOffset);
      postProcessed(segmentSize);
    }

    if (toProcess > 0) {
      _encodeAllSegment(result, processed, toProcess, newOffset);
    }

    return result;
  }

  void _encodeFirstSegment(
    Uint8List buffer,
    int start,
    int length,
    int offset,
  ) {
    for (var i = 0; i < length; i++) {
      buffer[start + i] ^= originKey[_getSegmentKey(index: offset + i)];
    }
  }

  void _encodeAllSegment(
    Uint8List buffer,
    int start,
    int length,
    int offset,
  ) {
    final newSeedBox = Uint8List.fromList(seedBox);
    final skipLength = (offset % segmentSize) +
        _getSegmentKey(index: offset ~/ segmentSize);

    var left = 0;
    var right = 0;
    for (var index = -skipLength; index < length; index++) {
      left = (left + 1) % originKeyLength;
      right = (newSeedBox[left] + right) % originKeyLength;
      final temp = newSeedBox[right];
      newSeedBox[right] = newSeedBox[left];
      newSeedBox[left] = temp;

      if (index >= 0) {
        final seedValue = newSeedBox[left] + newSeedBox[right];
        buffer[start + index] ^=
            newSeedBox[seedValue % originKeyLength];
      }
    }
  }

  int _getSegmentKey({required int index}) {
    final seed = originKey[index % originKeyLength];
    if (seed == 0) {
      return 0;
    }
    final value = (hashValue / ((index + 1) * seed)) * 100;
    return value.floor() % originKeyLength;
  }
}
