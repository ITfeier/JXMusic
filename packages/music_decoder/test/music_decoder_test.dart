import 'package:music_decoder/music_decoder.dart';
import 'package:test/test.dart';

void main() {
  group('NcmMetadata', () {
    test('parses artist list from metadata', () {
      final metadata = NcmMetadata.fromJson({
        'format': 'flac',
        'musicName': 'Sample Track',
        'album': 'Sample Album',
        'artist': [
          ['Artist One', 1],
          ['Artist Two', 2],
        ],
      });

      expect(metadata.format, 'flac');
      expect(metadata.title, 'Sample Track');
      expect(metadata.album, 'Sample Album');
      expect(metadata.artists, ['Artist One', 'Artist Two']);
    });

    test('falls back to defaults when metadata is empty', () {
      final metadata = NcmMetadata.fromJson({});

      expect(metadata.format, 'mp3');
      expect(metadata.title, 'Unknown Title');
      expect(metadata.album, 'Unknown Album');
      expect(metadata.artists, ['Unknown Artist']);
    });
  });

  group('QmcDecoder', () {
    test('exposes supported extensions', () {
      expect(QmcDecoder.supportedExtensions, contains('qmcflac'));
      expect(QmcDecoder.supportedExtensions, contains('qmc0'));
    });
  });
}
