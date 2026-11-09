import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/local_formats/format_decoder.dart';
import 'package:jxmusic/services/local_formats/kgm_decoder.dart';

import '../support/kgm_fixture.dart';

/// 真实酷狗公钥表（8 MiB，覆盖约 128 MiB 音频）。测试只读前 64 KiB。
final File _keyAsset = File('assets/kugou_key.bin');
final bool _hasKeyAsset = _keyAsset.existsSync();

const String _skipReason =
    '缺少 assets/kugou_key.bin（请在 JXMusic 项目根目录运行 flutter test），'
    '跳过酷狗真实公钥表回环测试';

/// 跨语言黄金向量（`评审记录.md` §3.3，由架构评独立 Python 复算）。
/// 密文 100 B → 明文 100 B；同时覆盖公式、相位/列索引、scramble、边界与
/// 17 字节私钥（cryptoTest 末字节为 0x01，第 17 字节必须补 0x00）。
const String _goldenCryptoTestHex = '102030405060708090a0b0c0d0e0f001';
const String _goldenPubKeyHex = '0763c800ff0d2abc';
const String _goldenCipherHex =
    '0714212e3b4855626f7c8996a3b0bdcad7e4f1fe0b1825323f4c596673808d9a'
    'a7b4c1cedbe8f5020f1c293643505d6a7784919eabb8c5d2dfecf90613202d'
    '3a4754616e7b8895a2afbcc9d6e3f0fd0a1724313e4b5865727f8c99a6b3c0'
    'cddae7f4010e';
const String _goldenPlainHex =
    '28869b6bd580faf9cb68bf002287f74b2b39f72091c55ef68b0338cb2a72c1'
    '7177a597b3c55e840dfb5c0cd33e65cb98a1ca78c065f9aca4939fa0d45542'
    '0f61dc3bf0a8b13e2cebbd50845fb58eafc2bfbb3c3da4579656ef83f68603'
    '133edfc4fd5934';

Directory? _tempDir;
Uint8List? _pubKey;
var _fileSeq = 0;

Uint8List _hex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 512 字节假公钥表，供不需要真实公钥表的异常路径测试使用。
Uint8List _dummyPubKey() =>
    Uint8List.fromList(List<int>.generate(512, (i) => i & 0xff));

Future<Uint8List> _readKeyPrefix([int maxBytes = 64 * 1024]) async {
  final raf = await _keyAsset.open();
  try {
    return await raf.read(maxBytes);
  } finally {
    await raf.close();
  }
}

Future<File> _writeSample(String name, Uint8List bytes) async {
  final file =
      File('${_tempDir!.path}${Platform.pathSeparator}${_fileSeq++}_$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

File _outputFile(String name) =>
    File('${_tempDir!.path}${Platform.pathSeparator}${_fileSeq++}_$name');

Matcher _errorMessage(Matcher messageMatcher) => throwsA(
      isA<FormatDecodeException>()
          .having((e) => e.message, 'message', messageMatcher),
    );

void main() {
  setUpAll(() async {
    _tempDir = await Directory.systemTemp.createTemp('kgm_decoder_test_');
    if (_hasKeyAsset) {
      _pubKey = await _readKeyPrefix();
    }
  });

  tearDownAll(() async {
    final dir = _tempDir;
    if (dir != null && dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  group('KgmDecoder 接口与魔数', () {
    test('sourceExtensions 含 kgm/kgma/vpr/kgg，outputExtension 为 null', () {
      final decoder = KgmDecoder();
      expect(
        decoder.sourceExtensions,
        <String>{'kgm', 'kgma', 'vpr', 'kgg'},
      );
      expect(decoder.outputExtension, isNull);
    });

    test('canDecode 识别 KGM / VPR / KGG magic，拒绝无关文件头', () async {
      final decoder = KgmDecoder();
      final dummy = _dummyPubKey();
      final kgm = await _writeSample(
        'magic.kgm',
        KgmFixture.buildFile(
          payload: Uint8List(32),
          pubKey: dummy,
          encrypt: false,
        ),
      );
      final vpr = await _writeSample(
        'magic.vpr',
        KgmFixture.buildFile(
          payload: Uint8List(32),
          pubKey: dummy,
          magic: KgmFixture.vprMagic,
          encrypt: false,
        ),
      );
      // R-16：.kgg 与 KGM 共用 magic，必须先能被识别（后续再给「暂不支持」）。
      final kgg = await _writeSample(
        'magic.kgg',
        KgmFixture.buildFile(
          payload: Uint8List(32),
          pubKey: dummy,
          cryptoVersion: 5,
          encrypt: false,
        ),
      );
      final other = await _writeSample(
        'other.kgm',
        Uint8List.fromList(List<int>.filled(2048, 0x42)),
      );

      expect(await decoder.canDecode(kgm), isTrue);
      expect(await decoder.canDecode(vpr), isTrue);
      expect(await decoder.canDecode(kgg), isTrue);
      expect(await decoder.canDecode(other), isFalse);
    });

    test('canDecode 要求文件长度 ≥ 1040（1024 字节头 + 1 块音频）', () async {
      final decoder = KgmDecoder();
      final dummy = _dummyPubKey();
      final short = await _writeSample(
        'short.kgm',
        KgmFixture.buildFile(
          payload: Uint8List(15),
          pubKey: dummy,
          encrypt: false,
        ),
      );
      final enough = await _writeSample(
        'enough.kgm',
        KgmFixture.buildFile(
          payload: Uint8List(16),
          pubKey: dummy,
          encrypt: false,
        ),
      );
      expect(await short.length(), 1039);
      expect(await enough.length(), 1040);
      expect(await decoder.canDecode(short), isFalse);
      expect(await decoder.canDecode(enough), isTrue);
    });

    test('文件短于 16 字节 magic 时 canDecode 返回 false', () async {
      final file = await _writeSample(
        'tiny.kgm',
        Uint8List.fromList(KgmFixture.kgmMagic.take(8).toList()),
      );
      expect(await KgmDecoder().canDecode(file), isFalse);
    });

    test('readTags 返回 null（酷狗文件无独立标签块）', () async {
      final file = await _writeSample(
        'tags.kgm',
        KgmFixture.buildFile(
          payload: Uint8List(16),
          pubKey: _dummyPubKey(),
          encrypt: false,
        ),
      );
      expect(await KgmDecoder().readTags(file), isNull);
    });

    test('夹具常量与 kgm.js 参考实现一致（交叉验证）', () {
      expect(KgmFixture.mendTable.length, KgmDecoder.mendTableLen);
      expect(KgmFixture.mendTable.first, 0xB8);
      expect(KgmFixture.mendTable[16], 0x2F);
      expect(KgmFixture.mendTable.last, 0x50);
      expect(KgmFixture.kgmMagic.first, 0x7c);
      expect(KgmFixture.vprMagic.first, 0x05);
      expect(KgmFixture.kgmMagic.length, 16);
      expect(KgmFixture.vprMagic.length, 16);
    });

    test('跨语言黄金向量：100 B 密文 → 明文逐字节一致（R-14）', () {
      final cipher = _hex(_goldenCipherHex);
      final plain = KgmDecoder.decryptAudioBytes(
        cipher,
        cryptoTest16: _hex(_goldenCryptoTestHex),
        pubKey: _hex(_goldenPubKeyHex),
      );
      expect(cipher, hasLength(100));
      expect(plain, hasLength(100));
      expect(plain, _hex(_goldenPlainHex));
    });

    test('任意块边界分段解密与整段一致（K-8 / K-9）', () {
      final cipher = _hex(_goldenCipherHex);
      final cryptoTest = _hex(_goldenCryptoTestHex);
      final pubKey = _hex(_goldenPubKeyHex);
      // 37 不是 16 的倍数：第二段从块中间开始，验证块号全局连续。
      final first = KgmDecoder.decryptAudioBytes(
        Uint8List.sublistView(cipher, 0, 37),
        cryptoTest16: cryptoTest,
        pubKey: pubKey,
      );
      final second = KgmDecoder.decryptAudioBytes(
        Uint8List.sublistView(cipher, 37),
        cryptoTest16: cryptoTest,
        pubKey: pubKey,
        startPosition: 37,
      );
      expect(
        Uint8List.fromList(<int>[...first, ...second]),
        _hex(_goldenPlainHex),
      );
    });
  });

  group('异常路径：统一抛中文 FormatDecodeException', () {
    final dummy = _dummyPubKey();
    late KgmDecoder decoder;

    setUp(() {
      decoder = KgmDecoder(pubKeyLoader: () async => dummy);
    });

    test('cryptoVersion=5（KGG）→ 明确离线不可解', () async {
      final file = await _writeSample(
        'sample.kgg',
        KgmFixture.buildFile(
          payload: KgmFixture.buildWavPcm(),
          pubKey: dummy,
          cryptoVersion: 5,
        ),
      );
      await expectLater(
        decoder.decodeTo(file, _outputFile('kgg.out')),
        _errorMessage(equals('酷狗 KGG 格式需要客户端密钥，暂不支持离线解密')),
      );
    });

    test('文件头被截断（不足 1024 字节）→ 文件不完整', () async {
      final valid = KgmFixture.buildFile(
        payload: Uint8List(64),
        pubKey: dummy,
      );
      final file = await _writeSample(
        'truncated.kgm',
        Uint8List.sublistView(valid, 0, 600),
      );
      await expectLater(
        decoder.decodeTo(file, _outputFile('truncated.out')),
        _errorMessage(contains('文件不完整或密钥损坏')),
      );
    });

    test('audioOffset=4（小于 1024）→ 偏移异常', () async {
      final file = await _writeSample(
        'offset-4.kgm',
        KgmFixture.buildFile(
          payload: Uint8List(64),
          pubKey: dummy,
          audioOffset: 4,
        ),
      );
      await expectLater(
        decoder.decodeTo(file, _outputFile('offset-4.out')),
        _errorMessage(contains('音频起始偏移异常')),
      );
    });

    test('audioOffset 超出文件长度 → 偏移异常', () async {
      final file = await _writeSample(
        'offset-large.kgm',
        KgmFixture.buildFile(
          payload: Uint8List(64),
          pubKey: dummy,
          audioOffset: 1 << 20,
        ),
      );
      await expectLater(
        decoder.decodeTo(file, _outputFile('offset-large.out')),
        _errorMessage(contains('音频起始偏移异常')),
      );
    });

    test('空音频（audioOffset == 文件长度）→ 偏移异常', () async {
      final file = await _writeSample(
        'empty-audio.kgm',
        KgmFixture.buildFile(payload: Uint8List(0), pubKey: dummy),
      );
      expect(await file.length(), KgmFixture.headerLen);
      await expectLater(
        decoder.decodeTo(file, _outputFile('empty-audio.out')),
        _errorMessage(contains('音频起始偏移异常')),
      );
    });

    test('magic 不匹配 → 不是酷狗加密文件', () async {
      final file = await _writeSample(
        'bad-magic.kgm',
        Uint8List.fromList(List<int>.filled(2048, 0x42)),
      );
      await expectLater(
        decoder.decodeTo(file, _outputFile('bad-magic.out')),
        _errorMessage(contains('不是酷狗 KGM/VPR 加密文件')),
      );
    });

    test('公钥表加载失败 → 酷狗公钥表缺失（R-8 / K-20）', () async {
      final brokenDecoder = KgmDecoder(
        pubKeyLoader: () async =>
            throw const FileSystemException('找不到 kugou_key.bin'),
      );
      final file = await _writeSample(
        'load-fail.kgm',
        KgmFixture.buildFile(payload: Uint8List(64), pubKey: dummy),
      );
      await expectLater(
        brokenDecoder.decodeTo(file, _outputFile('load-fail.out')),
        _errorMessage(equals('酷狗公钥表缺失（assets/kugou_key.bin），无法解密')),
      );
    });

    test('公钥表为空 → 酷狗公钥表缺失', () async {
      final emptyDecoder = KgmDecoder(pubKeyLoader: () async => Uint8List(0));
      final file = await _writeSample(
        'empty-key.kgm',
        KgmFixture.buildFile(payload: Uint8List(64), pubKey: dummy),
      );
      await expectLater(
        emptyDecoder.decodeTo(file, _outputFile('empty-key.out')),
        _errorMessage(equals('酷狗公钥表缺失（assets/kugou_key.bin），无法解密')),
      );
    });

    test('音频块数超出公钥表覆盖 → 文件过大', () async {
      final tinyKeyDecoder = KgmDecoder(pubKeyLoader: () async => Uint8List(3));
      // 64 字节音频 = 4 块，大于 3 字节公钥表。
      final file = await _writeSample(
        'too-big.kgm',
        KgmFixture.buildFile(payload: Uint8List(64), pubKey: dummy),
      );
      await expectLater(
        tinyKeyDecoder.decodeTo(file, _outputFile('too-big.out')),
        _errorMessage(equals('文件过大，超出酷狗公钥表覆盖范围')),
      );
    });
  });

  group('回环：解密字节与原始 payload 一致', () {
    late Uint8List pubKey;
    late KgmDecoder decoder;

    setUp(() {
      pubKey = _pubKey!;
      decoder = KgmDecoder(pubKeyLoader: () async => pubKey);
    });

    test('KGM 回环：WAV PCM 字节一致、识别 wav、进度 0→1', () async {
      final payload = KgmFixture.buildWavPcm();
      final file = await _writeSample(
        'roundtrip.kgm',
        KgmFixture.buildFile(payload: payload, pubKey: pubKey),
      );
      final output = _outputFile('roundtrip.wav');
      final progress = <double>[];

      final format =
          await decoder.decodeTo(file, output, onProgress: progress.add);

      expect(format, 'wav');
      expect(await output.readAsBytes(), payload);
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

    test('VPR 回环：跨多个 16 KiB 读取块、末块不足 16 字节仍一致', () async {
      // 8 kHz × 2.5 s × 2 字节 ≈ 40 KB，覆盖 16 KiB 分块边界与不完整末块。
      final payload = KgmFixture.buildWavPcm(durationMs: 2500);
      expect(payload.length, greaterThan(32 * 1024));
      expect(payload.length % 16, isNot(0));

      final file = await _writeSample(
        'roundtrip.vpr',
        KgmFixture.buildFile(
          payload: payload,
          pubKey: pubKey,
          magic: KgmFixture.vprMagic,
        ),
      );
      final output = _outputFile('roundtrip_vpr.wav');

      final format = await decoder.decodeTo(file, output);

      expect(format, 'wav');
      expect(await output.readAsBytes(), payload);
    });

    test('输出格式嗅探：flac/ogg/m4a/mp3/wav', () async {
      final cases = <(List<int>, int, String)>[
        ('fLaC'.codeUnits, 0, 'flac'),
        ('OggS'.codeUnits, 0, 'ogg'),
        ('ftyp'.codeUnits, 4, 'm4a'),
        ('ID3'.codeUnits, 0, 'mp3'),
        (<int>[0xff, 0xfb], 0, 'mp3'),
        (KgmFixture.wavHeaderPrefix, 0, 'wav'),
      ];

      var seed = 1;
      for (final (prefix, offset, expected) in cases) {
        final payload = KgmFixture.payloadWithMagic(
          prefix: prefix,
          prefixOffset: offset,
          length: 64,
          seed: seed++,
        );
        final file = await _writeSample(
          'sniff_$expected.kgm',
          KgmFixture.buildFile(payload: payload, pubKey: pubKey),
        );
        final output = _outputFile('sniff_$expected.out');
        final format = await decoder.decodeTo(file, output);
        expect(format, expected, reason: 'payload 头 $prefix');
        expect(await output.readAsBytes(), payload);
      }
    });

    test('解密结果不是有效音频 → FormatDecodeException', () async {
      final file = await _writeSample(
        'unknown.kgm',
        KgmFixture.buildFile(payload: Uint8List(64), pubKey: pubKey),
      );
      await expectLater(
        decoder.decodeTo(file, _outputFile('unknown.out')),
        _errorMessage(equals('解密结果不是有效音频（文件可能已损坏或为不支持的变体）')),
      );
    });
  }, skip: _hasKeyAsset ? false : _skipReason);

  group('pubKeyLoader 注入', () {
    test('注入 File 读取器生效，连续两次解密只加载一次（R-8）', () async {
      var loadCount = 0;
      final decoder = KgmDecoder(pubKeyLoader: () async {
        loadCount++;
        return _readKeyPrefix();
      });
      final payloads = <Uint8List>[
        KgmFixture.buildWavPcm(durationMs: 120),
        KgmFixture.buildWavPcm(durationMs: 60),
      ];

      for (var i = 0; i < payloads.length; i++) {
        final file = await _writeSample(
          'inject_$i.kgm',
          KgmFixture.buildFile(payload: payloads[i], pubKey: _pubKey!),
        );
        final output = _outputFile('inject_$i.out');
        expect(await decoder.decodeTo(file, output), 'wav');
        expect(await output.readAsBytes(), payloads[i]);
      }

      expect(loadCount, 1, reason: '公钥表应缓存，多次解密只加载一次');
    });

    test('并发解码共享同一次公钥表加载（并发单飞，R-8）', () async {
      var loadCount = 0;
      final decoder = KgmDecoder(pubKeyLoader: () async {
        loadCount++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _readKeyPrefix();
      });
      final firstPayload = KgmFixture.buildWavPcm(durationMs: 120);
      final secondPayload = KgmFixture.buildWavPcm(durationMs: 60);
      final firstFile = await _writeSample(
        'concurrent_0.kgm',
        KgmFixture.buildFile(payload: firstPayload, pubKey: _pubKey!),
      );
      final secondFile = await _writeSample(
        'concurrent_1.kgm',
        KgmFixture.buildFile(payload: secondPayload, pubKey: _pubKey!),
      );

      final results = await Future.wait(<Future<String>>[
        decoder.decodeTo(firstFile, _outputFile('concurrent_0.out')),
        decoder.decodeTo(secondFile, _outputFile('concurrent_1.out')),
      ]);

      expect(results, <String>['wav', 'wav']);
      expect(loadCount, 1, reason: '并发解码应共享同一次加载（单飞）');
    });
  }, skip: _hasKeyAsset ? false : _skipReason);
}
