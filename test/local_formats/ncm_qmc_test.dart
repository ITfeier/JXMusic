// NCM / QMC 解密适配器单元测试。
//
// 样本来源分两类：
// 1) test/support/ncm_qmc_fixture.dart 现场合成的样本（加密侧独立实现，不走被测解密器）；
// 2) 硬编码的**跨语言黄金向量**：由独立 Node.js 实现（AES-128-ECB / 腾讯 TEA-CBC /
//    QMC 静态与 Map 流密码，按公开算法另写一遍生成，非本仓库 Dart 代码产出），
//    见各常量上方注释。负例统一断言 `FormatDecodeException` 类型 + 中文关键字。
//
// 真实文件覆盖边界：真实网易云/QQ 客户端下载的文件（尤其 musicex/STag 新尾部、
// 客户端密钥库）需人工验收；本套用例验证算法闭环与失败可解释性。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/local_formats/format_decoder.dart';
import 'package:jxmusic/services/local_formats/ncm_decoder.dart';
import 'package:jxmusic/services/local_formats/qmc_decoder.dart';
import 'package:music_decoder/music_decoder.dart' as md;

import '../support/ncm_qmc_fixture.dart';

final RegExp _chinese = RegExp('[\u4e00-\u9fa5]');

/// 跨语言黄金向量：QMC v1（固定 36 字节纯文本 → 静态密钥密文）。
/// 由独立 Node.js 实现生成；明文以 `fLaC` 开头以满足解码后容器自检。
const String _goldenQmcV1PlainHex =
    '664c614300112233445566778899aabbccddeeff'
    '00112233445566778899aabbccddeeff';
const String _goldenQmcV1FileHex =
    'a506b7899076d5619cf4001517c2a3bb'
    '0f837bdc9f02334d9cc759cb1822deb5'
    '0f9a9ac2';

/// 跨语言黄金向量：QMC v2（TEA-CBC 加密 EKey + Map 流密码，PcV1Legacy 尾包）。
/// 主密钥 = 05 10 1b ...（256 字节，Map 密码器按 0..255 索引），明文 28 字节以 `fLaC` 开头。
const String _goldenQmcV2PlainHex =
    '664c6143deadbeefcafebabe0011223344'
    '5566778899aabbccddeeff';
const String _goldenQmcV2FileBase64 =
    'mR2hX2E/fDw1IXsovwnjZrsIpWc3B2lsMwYuZUJSQWJKakU4UjFLVzdiNHgrMERtWmw5bGRZTDExR0tl'
    'eEdRZi9NSHREb1lPRWwwbTRIVE5yODZtVjN3dTNKckdvNUI0YnkxRDFvaXhwOTA4UFZvNmlIZjFBSWpX'
    'VUVhdEZ6Y08ramU4U29RaWFwdkxlWUZMS2JlUEowYmJkMlpwVjVxMDZkL09GNzYxMVFJeWIycndLblRI'
    'dnVHMHhWcEJpK0NmOE9NZCtuV2pWZnQ2REkveW01OUEySUJBMkhPc3VQMXZWcUtpRDgvWXkycmFFWHMw'
    'NjJybkM1YThKcnBpQSsrSTJkdWt5ZDdaN3hsYUJBdjhWQ2F5UFpTNy8ySlVZdEdpNDNIdXk3dXpETGZo'
    'R3JacGxRVzhxejBGaGlYTnkzYlVCVUU3TGNxcGcrdWg3a0Q5NW9mRTR6cjVlUXhMMzVkWFVVTXJwZlFv'
    'L3c4K3UxUzN3d1JmNEIwd3dvM0FUdk1vZDlJbDFXYz1sAQAA';

/// 跨语言黄金向量：NCM（format=wav 小负载 + 内嵌元数据/封面），AES-128-ECB 由
/// 独立 Node.js 的 crypto 模块加密，keybox/密钥流由独立 JS 实现生成。
const String _goldenNcmFileBase64 =
    'Q1RFTkZEQU0BcDAAAAAsztXraer7FFUNRb9h3Rcd9seW9M6koAUo46dcYoJTo25Z8L+Bt6FQh/qzru3ke+WuAAAA'
    'UlVQQwgGGksnDA1EF0MODAcKBRpKWQAmBBcSKxsUEwcxKAAhIDEzIQ8zCBA6WzYTCStMJCkuVBQzFEwsKg0EVgE6'
    'NDc3Wi8CEAFSChQZGxNSVilaCwYgKVU0MVErEQcxUSIXNiZQCw0BNEgRAgtaFBQhFCQaEFMTOwoGMFNbCjEsExoh'
    'EhYtOhErKAQFJTRWBBQ2TDopTA0nM1oJBw0GOVQGNyYWIREOFywIBF5eAAAAAAAAAAAADgAAAIlQTkcNChoKR09M'
    'REVOuDVBCDwSmnM/b7sJkn0rZljpKSwo7I2j+cgDLvstPXn6SrSqclOtZxr4doE=';
const String _goldenNcmAudioHex =
    '524946462400000057415645666d74201000000001000100401f0000803e000002001000'
    '6461746100000000';
const String _goldenNcmCoverHex = '89504e470d0a1a0a474f4c44454e';

/// 构造以指定音频容器开头的确定性小负载（供「按容器嗅探格式」用例）。
///
/// 末尾 4 字节固定为 0x7F：避免 QMC v1 文件末尾 4 字节被包内 v2 尾包启发式误判。
Uint8List _payloadForFormat(String format) {
  final body = List<int>.generate(48, (i) => (i * 29 + 3) & 0xFF);
  body[body.length - 1] = 0x7F;
  body[body.length - 2] = 0x7F;
  body[body.length - 3] = 0x7F;
  body[body.length - 4] = 0x7F;

  switch (format) {
    case 'flac':
      return Uint8List.fromList([...ascii.encode('fLaC'), ...body]);
    case 'ogg':
      return Uint8List.fromList([...ascii.encode('OggS'), ...body]);
    case 'm4a':
      return Uint8List.fromList([
        0x00,
        0x00,
        0x00,
        0x20,
        ...ascii.encode('ftypM4A '),
        ...body,
      ]);
    case 'wav':
      return Uint8List.fromList([
        ...ascii.encode('RIFF'),
        0x00,
        0x00,
        0x00,
        0x00,
        ...ascii.encode('WAVE'),
        ...body,
      ]);
    case 'mp3':
    default:
      return Uint8List.fromList([
        ...ascii.encode('ID3'),
        0x03,
        0x00,
        0x00,
        ...body,
      ]);
  }
}

/// 断言调用抛出带中文 message 的 [FormatDecodeException]，并返回该异常。
Future<FormatDecodeException> _expectFormatFailure(
  Future<Object?> action,
) async {
  try {
    await action;
  } on FormatDecodeException catch (error) {
    expect(error.message, matches(_chinese), reason: '失败文案必须是可展示的中文');
    return error;
  }
  throw StateError('期望抛出 FormatDecodeException，但调用成功返回');
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ncm_qmc_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  File writeFile(String name, List<int> bytes) {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(bytes);
    return file;
  }

  File outputFile(String name) =>
      File('${tempDir.path}${Platform.pathSeparator}$name');

  List<String> listFileNames() =>
      tempDir
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .toList()
        ..sort();

  group('NCM 适配器', () {
    test('canDecode 按文件头魔数识别，非 NCM 返回 false', () async {
      final fixture = buildNcmFixture(audioPayload: buildWavPayload());
      final decoder = NcmDecoder();

      final ncmFile = writeFile('song.ncm', fixture.bytes);
      expect(await decoder.canDecode(ncmFile), isTrue);

      final fake = writeFile('fake.ncm', utf8.encode('not-an-ncm-file'));
      expect(await decoder.canDecode(fake), isFalse);
      expect(await decoder.canDecode(outputFile('missing.ncm')), isFalse);
    });

    test('decodeTo 回环输出 WAV 负载，返回 wav 且进度 0→1', () async {
      final fixture = buildNcmFixture(audioPayload: buildWavPayload());
      final input = writeFile('loop.ncm', fixture.bytes);
      final output = outputFile('loop.wav');
      final progress = <double>[];

      final format = await NcmDecoder().decodeTo(
        input,
        output,
        onProgress: progress.add,
      );

      expect(format, 'wav');
      expect(await output.readAsBytes(), equals(fixture.audioPayload));
      expect(progress, isNotEmpty);
      expect(progress.first, 0.0);
      expect(progress.last, 1.0);
      for (final value in progress) {
        expect(value, inInclusiveRange(0.0, 1.0));
      }
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
    });

    test('readTags 解析标题/歌手/专辑与封面原始字节，且不产生输出文件', () async {
      final fixture = buildNcmFixture(
        audioPayload: buildWavPayload(),
        title: '夜曲',
        album: '十一月的萧邦',
        artists: ['周杰伦'],
      );
      final fullFile = writeFile('tags.ncm', fixture.bytes);
      final before = listFileNames();

      final tags = await NcmDecoder().readTags(fullFile);

      expect(tags, isNotNull);
      expect(tags!.title, '夜曲');
      expect(tags.artist, '周杰伦');
      expect(tags.album, '十一月的萧邦');
      expect(tags.coverBytes, equals(fixture.cover));
      expect(listFileNames(), equals(before), reason: 'readTags 不得写任何文件');
    });

    test('readTags 只读头部：去掉音频段的文件也能读标签', () async {
      final fixture = buildNcmFixture(audioPayload: buildWavPayload());
      // 只保留「魔数 + 密钥块 + 元数据 + 封面」，不含音频段：
      // readTags 若能成功，说明读取字节数 < 完整文件大小（R-13）。
      final headerOnly = writeFile(
        'header-only.ncm',
        fixture.bytes.sublist(0, fixture.audioOffset),
      );
      expect(headerOnly.lengthSync(), lessThan(fixture.bytes.length));

      final tags = await NcmDecoder().readTags(headerOnly);
      expect(tags, isNotNull);
      expect(tags!.title, '测试歌曲');
      expect(tags.coverBytes, equals(fixture.cover));
    });

    test('封面超过 8 MiB 上限时 coverBytes 返回 null（其余标签保留）', () async {
      final oversizedCover = Uint8List(8 * 1024 * 1024 + 1);
      oversizedCover.setRange(0, 8, [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      final fixture = buildNcmFixture(
        audioPayload: buildWavPayload(),
        title: '大封面',
        cover: oversizedCover,
      );
      final tags = await NcmDecoder().readTags(
        writeFile('big-cover.ncm', fixture.bytes),
      );

      expect(tags, isNotNull);
      expect(tags!.title, '大封面');
      expect(tags.coverBytes, isNull);
    });

    test('readTags 对非 NCM 文件返回 null（调用方回退文件名）', () async {
      final fake = writeFile('not.ncm', utf8.encode('plain-audio-data'));
      expect(await NcmDecoder().readTags(fake), isNull);
    });

    test('format=mp3 的 NCM 可解析标签，decodeTo 写 ID3 且保留音频负载', () async {
      final payload = buildWavPayload();
      final fixture = buildNcmFixture(
        audioPayload: payload,
        format: 'mp3',
        title: 'MP3 标题',
        album: 'MP3 专辑',
        artists: ['歌手甲', '歌手乙'],
      );
      final input = writeFile('tagged.ncm', fixture.bytes);

      final tags = await NcmDecoder().readTags(input);
      expect(tags, isNotNull);
      expect(tags!.title, 'MP3 标题');
      expect(tags.artist, '歌手甲/歌手乙');
      expect(tags.album, 'MP3 专辑');

      final output = outputFile('tagged.mp3');
      final format = await NcmDecoder().decodeTo(input, output);
      expect(format, 'mp3');
      final decoded = await output.readAsBytes();
      expect(String.fromCharCodes(decoded.sublist(0, 3)), 'ID3');
      expect(
        decoded.sublist(decoded.length - payload.length),
        equals(payload),
        reason: '写标签不能破坏音频负载',
      );
    });

    test('截断的 NCM 文件抛中文 FormatDecodeException', () async {
      final fixture = buildNcmFixture(audioPayload: buildWavPayload());
      final truncated = writeFile('broken.ncm', fixture.bytes.sublist(0, 40));

      final error = await _expectFormatFailure(
        NcmDecoder().decodeTo(truncated, outputFile('broken-out.wav')),
      );
      expect(error.message, contains('不完整'));
    });

    test('音频密钥块损坏时抛中文 FormatDecodeException', () async {
      final fixture = buildNcmFixture(audioPayload: buildWavPayload());
      final corrupted = Uint8List.fromList(fixture.bytes);
      final keyLength =
          corrupted[10] |
          (corrupted[11] << 8) |
          (corrupted[12] << 16) |
          (corrupted[13] << 24);
      // 改坏密钥密文的最后一个字节（PKCS7 填充校验必然失败）。
      corrupted[14 + keyLength - 1] = corrupted[14 + keyLength - 1] ^ 0xFF;

      final error = await _expectFormatFailure(
        NcmDecoder().decodeTo(
          writeFile('corrupt.ncm', corrupted),
          outputFile('corrupt-out.wav'),
        ),
      );
      expect(error.message, contains('损坏'));
    });

    test('R-23 元数据长度越界（超剩余/超上限）时抛中文 FormatDecodeException', () async {
      final fixture = buildNcmFixture(audioPayload: buildWavPayload());
      final keyLength =
          fixture.bytes[10] |
          (fixture.bytes[11] << 8) |
          (fixture.bytes[12] << 16) |
          (fixture.bytes[13] << 24);
      final metaLengthOffset = 14 + keyLength;
      final metaRemaining = fixture.bytes.length - (metaLengthOffset + 4);

      // 0xFFFFFFFF（超上限）与 remaining+100（超剩余文件）都必须拒绝。
      for (final value in <int>[0xFFFFFFFF, metaRemaining + 100]) {
        final corrupted = Uint8List.fromList(fixture.bytes);
        corrupted[metaLengthOffset] = value & 0xFF;
        corrupted[metaLengthOffset + 1] = (value >> 8) & 0xFF;
        corrupted[metaLengthOffset + 2] = (value >> 16) & 0xFF;
        corrupted[metaLengthOffset + 3] = (value >> 24) & 0xFF;

        final error = await _expectFormatFailure(
          NcmDecoder().decodeTo(
            writeFile('meta-$value.ncm', corrupted),
            outputFile('meta-$value.wav'),
          ),
        );
        expect(error.message, contains('元数据长度异常'));
        expect(
          await NcmDecoder().readTags(
            writeFile('meta-tags-$value.ncm', corrupted),
          ),
          isNull,
        );
      }
    });

    test('R-26 metaLength=0（无元数据块）仍可解码，格式按文件大小推断', () async {
      final payload = buildWavPayload();
      final source = buildNcmFixture(
        audioPayload: payload,
        cover: Uint8List(0),
      );
      // 由合成样本改造出「无元数据块」合法形态：把 metaLen 改 0 并移除 metaData 段。
      final keyLength =
          source.bytes[10] |
          (source.bytes[11] << 8) |
          (source.bytes[12] << 16) |
          (source.bytes[13] << 24);
      final metaLengthOffset = 14 + keyLength;
      final metaLength = readUint32Le(source.bytes, metaLengthOffset);
      final noMetaBytes = Uint8List.fromList([
        ...source.bytes.sublist(0, metaLengthOffset),
        0x00,
        0x00,
        0x00,
        0x00,
        ...source.bytes.sublist(metaLengthOffset + 4 + metaLength),
      ]);
      final input = writeFile('no-meta.ncm', noMetaBytes);

      // 无标签可读，返回 null 且不抛异常。
      expect(await NcmDecoder().readTags(input), isNull);

      final output = outputFile('no-meta.out');
      final format = await NcmDecoder().decodeTo(input, output);
      // 小文件（<16 MiB）→ 按 vendored 包语义推断为 mp3，解码继续。
      expect(format, 'mp3');
      final decoded = await output.readAsBytes();
      expect(
        String.fromCharCodes(decoded.sublist(0, 3)),
        'ID3',
        reason: 'mp3 容器（包会写入标签头）',
      );
      expect(decoded.sublist(decoded.length - payload.length), equals(payload));
    });

    test('跨语言黄金向量：固定 NCM 样本解码出既定音频与标签', () async {
      final golden = base64.decode(_goldenNcmFileBase64);
      final input = writeFile('golden.ncm', golden);
      final expectedAudio = hexToBytes(_goldenNcmAudioHex);

      final tags = await NcmDecoder().readTags(input);
      expect(tags, isNotNull);
      expect(tags!.title, '黄金NCM');
      expect(tags.album, '黄金专辑');
      expect(tags.artist, '黄金歌手');
      expect(tags.coverBytes, equals(hexToBytes(_goldenNcmCoverHex)));

      final output = outputFile('golden-out.wav');
      final format = await NcmDecoder().decodeTo(input, output);
      expect(format, 'wav');
      expect(await output.readAsBytes(), equals(expectedAudio));
    });
  });

  group('QMC 适配器', () {
    test('sourceExtensions 与包内 qmcExtensionMap 清单一致', () {
      final decoder = QmcDecoder();
      final expected = md.QmcDecoder.supportedExtensions
          .map((extension) => extension.toLowerCase())
          .toSet();

      expect(decoder.sourceExtensions.length, expected.length);
      expect(decoder.sourceExtensions, containsAll(expected));
      expect(decoder.sourceExtensions, contains('qmc3'));
      expect(decoder.sourceExtensions, contains('mflac'));
      expect(decoder.sourceExtensions, contains('mgg'));
    });

    test('跨语言黄金向量：QMC v1 固定密文解出既定明文', () async {
      final decoder = QmcDecoder();
      final input = writeFile('golden.qmc3', hexToBytes(_goldenQmcV1FileHex));
      final expected = hexToBytes(_goldenQmcV1PlainHex);

      expect(await decoder.canDecode(input), isTrue);
      final output = outputFile('golden-v1.flac');
      final format = await decoder.decodeTo(input, output);
      // R-22：输出格式以容器嗅探为准（明文以 fLaC 开头 → flac），不按 .qmc3 映射。
      expect(format, 'flac');
      expect(await output.readAsBytes(), equals(expected));
    });

    test('跨语言黄金向量：QMC v2 固定 EKey/密文解出既定明文（deriveKey 真实路径）', () async {
      final decoder = QmcDecoder();
      final input = writeFile(
        'golden.mflac',
        base64.decode(_goldenQmcV2FileBase64),
      );
      final expected = hexToBytes(_goldenQmcV2PlainHex);

      expect(await decoder.canDecode(input), isTrue);
      final output = outputFile('golden-v2.flac');
      final format = await decoder.decodeTo(input, output);
      expect(format, 'flac');
      expect(await output.readAsBytes(), equals(expected));
    });

    test('QMC v1 静态密钥回环：扩展名只用于识别，输出格式按容器嗅探', () async {
      final payload = buildWavPayload();
      final v1Bytes = buildQmcV1Fixture(payload);
      const extensions = <String>[
        'qmc0',
        'qmc2',
        'qmc3',
        'bkcmp3',
        'bkcflac',
        'tkm',
        '666c6163',
        '6d7033',
        '6f6767',
        '6d3461',
        '776176',
      ];

      for (final extension in extensions) {
        final decoder = QmcDecoder();
        final input = writeFile('v1-$extension.$extension', v1Bytes);
        final output = outputFile('v1-$extension.decoded');

        expect(
          await decoder.canDecode(input),
          isTrue,
          reason: 'v1 扩展名 $extension 无需尾包也应被识别',
        );
        final format = await decoder.decodeTo(input, output);
        // R-22：负载是 WAV（RIFF 开头），即便扩展名是 qmc2/bkcflac 也返回 wav。
        expect(format, 'wav', reason: '扩展名 $extension 的返回格式应按容器嗅探');
        expect(
          await output.readAsBytes(),
          equals(payload),
          reason: '扩展名 $extension 应解出原始负载',
        );
      }
    });

    test('R-22 输出格式按容器嗅探纠正（qmcogg 实际为 WAV / MP3）', () async {
      for (final format in <String>['wav', 'mp3']) {
        // .qmcogg 按扩展名映射应是 ogg，但实际容器是 WAV/MP3 → 必须返回嗅探结果。
        final payload = _payloadForFormat(format);
        final fixture = buildQmcV2Fixture(
          audioPayload: payload,
          masterKey: buildQmcMasterKey(256),
        );
        final input = writeFile('sniff-$format.qmcogg', fixture.bytes);
        final output = outputFile('sniff-$format.out');
        final decodedFormat = await QmcDecoder().decodeTo(input, output);

        expect(decodedFormat, format, reason: '嗅探到 $format 时应返回该格式');
        expect(await output.readAsBytes(), equals(payload));
      }
    });

    test('QMC v2 Map 密钥（≤300 字节）PC 传统尾部回环（mflac→flac）', () async {
      final payload = _payloadForFormat('flac');
      final fixture = buildQmcV2Fixture(
        audioPayload: payload,
        masterKey: buildQmcMasterKey(256),
      );
      final input = writeFile('map-tail.mflac', fixture.bytes);
      final output = outputFile('map-tail.flac');
      final decoder = QmcDecoder();
      final progress = <double>[];

      expect(await decoder.canDecode(input), isTrue);
      final format = await decoder.decodeTo(
        input,
        output,
        onProgress: progress.add,
      );
      expect(format, 'flac');
      expect(await output.readAsBytes(), equals(payload));
      expect(progress, isNotEmpty);
      expect(progress.first, 0.0);
      expect(progress.last, 1.0);
    });

    test('QMC v2 RC4 密钥（>300 字节）QTag 尾部回环（mgg→ogg）', () async {
      final payload = _payloadForFormat('ogg');
      final fixture = buildQmcV2Fixture(
        audioPayload: payload,
        masterKey: buildQmcMasterKey(320),
        tailStyle: QmcKeyTailStyle.qTag,
      );
      final input = writeFile('rc4-qtag.mgg', fixture.bytes);
      final output = outputFile('rc4-qtag.ogg');
      final decoder = QmcDecoder();

      expect(await decoder.canDecode(input), isTrue);
      final format = await decoder.decodeTo(input, output);
      expect(format, 'ogg');
      expect(await output.readAsBytes(), equals(payload));
    });

    test('readTags 对 QMC 返回 null（解密后再读音频元数据）', () async {
      final input = writeFile(
        'tags.qmc3',
        buildQmcV1Fixture(buildWavPayload()),
      );
      expect(await QmcDecoder().readTags(input), isNull);
    });

    test('musicex 尾部（无密钥标记）抛中文错误', () async {
      final bytes = buildQmcMusicExTailFixture(audioPayload: buildWavPayload());
      final input = writeFile('musicex.mgg', bytes);
      final decoder = QmcDecoder();

      expect(await decoder.canDecode(input), isTrue);
      final error = await _expectFormatFailure(
        decoder.decodeTo(input, outputFile('musicex.ogg')),
      );
      expect(error.message, contains('不含密钥'));
      expect(error.message, contains('musicex'));
    });

    test('STag 尾部（无 EKey）抛中文错误', () async {
      final bytes = buildQmcSTagFixture(audioPayload: buildWavPayload());
      final input = writeFile('stag.mgg', bytes);
      final decoder = QmcDecoder();

      expect(await decoder.canDecode(input), isTrue);
      final error = await _expectFormatFailure(
        decoder.decodeTo(input, outputFile('stag.ogg')),
      );
      expect(error.message, contains('不含密钥'));
    });

    test('v2 扩展名缺少内嵌密钥尾部时给出中文原因', () async {
      final bytes = Uint8List.fromList([
        ...utf8.encode('QQMusic-encrypted-audio-payload'),
        0xFF,
        0xFF,
        0xFF,
        0xFF,
      ]);
      final input = writeFile('no-key.mflac', bytes);
      final decoder = QmcDecoder();

      expect(await decoder.canDecode(input), isFalse);
      final error = await _expectFormatFailure(
        decoder.decodeTo(input, outputFile('no-key.flac')),
      );
      expect(error.message, contains('不含密钥'));
    });

    test('损坏的 v2 尾部密钥抛中文错误', () async {
      final bytes = buildQmcCorruptKeyFixture(audioPayload: buildWavPayload());
      final input = writeFile('corrupt.mflac', bytes);

      final error = await _expectFormatFailure(
        QmcDecoder().decodeTo(input, outputFile('corrupt.flac')),
      );
      expect(error.message, contains('密钥'));
    });

    test('解码后自检：解出非音频容器时抛「解密结果不是有效音频」', () async {
      // qmc3 后缀（v1 静态密钥），明文故意不是任何合法音频容器。
      final garbage = Uint8List.fromList([
        ...utf8.encode('this-is-not-a-legal-audio-container'),
        0xFF,
        0xFF,
        0xFF,
        0xFF,
      ]);
      final input = writeFile('garbage.qmc3', buildQmcV1Fixture(garbage));

      final error = await _expectFormatFailure(
        QmcDecoder().decodeTo(input, outputFile('garbage.mp3')),
      );
      expect(error.message, contains('解密结果不是有效音频'));
    });

    test('不支持的扩展名抛中文错误', () async {
      final input = writeFile(
        'plain.ogg',
        buildQmcV1Fixture(buildWavPayload()),
      );
      final decoder = QmcDecoder();

      expect(await decoder.canDecode(input), isFalse);
      final error = await _expectFormatFailure(
        decoder.decodeTo(input, outputFile('plain-decoded.ogg')),
      );
      expect(error.message, contains('扩展名'));
    });

    test('过短的 QMC 文件抛中文错误', () async {
      final input = writeFile('short.qmc3', [0x01, 0x02, 0x03]);
      final decoder = QmcDecoder();

      expect(await decoder.canDecode(input), isFalse);
      final error = await _expectFormatFailure(
        decoder.decodeTo(input, outputFile('short.mp3')),
      );
      expect(error.message, contains('不完整'));
    });
  });
}
