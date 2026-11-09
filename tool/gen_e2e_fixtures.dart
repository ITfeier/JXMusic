// E2E 合成音频样本生成器（纯 Dart，QA 验收用）。
//
// 目的：不随包分发任何真实版权样本，也能在 Android 模拟器上端到端验证
// 「扫描 → 识别 → 解密 → 播放 → 元数据回填」整条链路。
//
// 用法（任选其一，见任务 task-6）：
//   D:\Programs\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/gen_e2e_fixtures.dart
//   D:\Programs\flutter\bin\flutter.bat pub get --offline  # 前置：生成 .dart_tool/package_config.json
//
// 输出：build/e2e_music/（默认，可用 --out=DIR 覆盖）
// 构造器复用 test/support 下的纯 Dart 夹具：
// - ncm_qmc_fixture.dart：NCM（AES-ECB keybox + RC4 流）、QMC v1 静态密钥、QMC v2 TEA-CBC 尾部 EKey；
// - kgm_fixture.dart：KGM/VPR 加密侧（严格逆运算，公钥取真实 assets/kugou_key.bin 前缀）。
//
// 说明：解密侧实现（lib/services/local_formats/*）不在此处调用，样本只负责"加密侧"，
// 保证 E2E 验证的是被测实现的真实密钥派生路径。

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../test/support/kgm_fixture.dart';
import '../test/support/ncm_qmc_fixture.dart';

const String _defaultOutDir = 'build/e2e_music';
const String _pubKeyAsset = 'assets/kugou_key.bin';

/// 每个样本的生成结果（打印 + 报告用）。
class _Generated {
  const _Generated({
    required this.file,
    required this.size,
    required this.headHex,
    required this.note,
  });

  final File file;
  final int size;
  final String headHex;
  final String note;
}

Future<void> main(List<String> args) async {
  final outDirArg = args
      .firstWhere((arg) => arg.startsWith('--out='), orElse: () => '')
      .replaceFirst('--out=', '');
  final outDir = outDirArg.trim().isEmpty ? _defaultOutDir : outDirArg.trim();
  final out = Directory(outDir);

  // 清空旧样本，避免上次运行的残留文件混入本次扫描断言。
  if (out.existsSync()) {
    out.deleteSync(recursive: true);
  }
  out.createSync(recursive: true);

  final pubKey = _readPubKeyPrefix(_pubKeyAsset);
  final wavPayload = buildWavPayload(
    sampleRate: 8000,
    milliseconds: 12000,
    frequency: 440,
  );
  final kgmPayload = KgmFixture.buildWavPcm(
    sampleRate: 8000,
    durationMs: 12000,
    frequency: 440,
  );

  final generated = <_Generated>[
    await _write(
      out,
      '01_plain.wav',
      wavPayload,
      note: '普通 WAV（不经过解密器，直接交给 libmpv）',
    ),
    await _write(
      out,
      '02_ncm.ncm',
      buildNcmFixture(
        audioPayload: wavPayload,
        format: 'wav',
        title: 'NCM-测试歌曲',
        album: 'E2E测试专辑',
        artists: const ['E2E测试歌手'],
      ).bytes,
      note: '网易云 NCM（内嵌标题/歌手/专辑/封面，音频为 WAV PCM）',
    ),
    await _write(
      out,
      '03_qmc3.qmc3',
      buildQmcV1Fixture(wavPayload),
      note: 'QQ 音乐 QMC v1（qmc3 静态密钥）',
    ),
    await _write(
      out,
      '04_mflac.mflac',
      buildQmcV2Fixture(
        audioPayload: wavPayload,
        masterKey: buildQmcMasterKey(256),
      ).bytes,
      note: 'QQ 音乐 QMC v2（mflac，PC 尾部 EKey + Map 流密码）',
    ),
    await _write(
      out,
      '05_kgm.kgm',
      KgmFixture.buildFile(
        payload: kgmPayload,
        pubKey: pubKey,
        magic: KgmFixture.kgmMagic,
        cryptoVersion: 3,
      ),
      note: '酷狗 KGM（公钥表取 assets/kugou_key.bin 前 128 KiB，音频 WAV）',
    ),
    await _write(
      out,
      '06_vpr.vpr',
      KgmFixture.buildFile(
        payload: kgmPayload,
        pubKey: pubKey,
        magic: KgmFixture.vprMagic,
        cryptoVersion: 3,
      ),
      note: '酷狗 VPR（算法同 KGM，magic 不同，音频 WAV）',
    ),
    await _write(
      out,
      '07_kgg.kgg',
      KgmFixture.buildFile(
        payload: kgmPayload,
        pubKey: pubKey,
        magic: KgmFixture.kgmMagic,
        cryptoVersion: 5,
        encrypt: false,
      ),
      note: '酷狗 KGG（cryptoVersion=5，离线无解；仅验证识别 + 中文提示）',
    ),
  ];

  stdout.writeln('输出目录：${out.absolute.path}');
  stdout.writeln('=' * 88);
  var total = 0;
  for (final item in generated) {
    total += item.size;
    final digest = sha256.convert(item.file.readAsBytesSync()).toString();
    stdout.writeln('${item.file.uri.pathSegments.last}');
    stdout.writeln('  size     : ${item.size} B  (${item.size / 1024} KiB)');
    stdout.writeln('  head     : ${item.headHex}');
    stdout.writeln('  sha256   : $digest');
    stdout.writeln('  note     : ${item.note}');
  }
  stdout.writeln('=' * 88);
  stdout.writeln(
    '共 ${generated.length} 个样本，合计 $total B（${(total / 1024).toStringAsFixed(1)} KiB）',
  );

  // 自检：加密样本与明文 WAV 字节不同，避免"样本其实没加密"的假验证。
  final plainWav = generated.first.file.readAsBytesSync();
  for (final index in <int>[1, 2, 3, 4, 5]) {
    final encrypted = generated[index].file.readAsBytesSync();
    final tail = encrypted.sublist(encrypted.length - plainWav.length);
    if (bytesEqual(tail, plainWav)) {
      stderr.writeln('自检失败：${generated[index].file.path} 尾部与明文 WAV 完全相同');
      exitCode = 1;
      return;
    }
  }
  stdout.writeln('自检：加密样本均不含明文 WAV 尾部（非空跑）');
}

Future<_Generated> _write(
  Directory outDir,
  String name,
  List<int> bytes, {
  required String note,
}) async {
  final file = File('${outDir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes, flush: true);
  return _Generated(
    file: file,
    size: bytes.length,
    headHex: _hex(bytes.take(16).toList()),
    note: note,
  );
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// 取真实公钥表前若干字节：KGM 每 1 字节覆盖 16 字节音频，
/// 192 KiB 音频（12 秒 WAV）只需 12,288 字节；取 128 KiB 留足余量。
Uint8List _readPubKeyPrefix(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('缺少酷狗公钥表：$path（KGM/VPR 样本无法生成）');
    exitCode = 1;
    return Uint8List(0);
  }
  final raf = file.openSync();
  try {
    final buffer = Uint8List(128 * 1024);
    final read = raf.readIntoSync(buffer);
    return Uint8List.sublistView(buffer, 0, read);
  } finally {
    raf.closeSync();
  }
}
