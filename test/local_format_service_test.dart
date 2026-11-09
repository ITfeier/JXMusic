import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/local_format_service.dart';
import 'package:jxmusic/services/local_formats/format_decoder.dart';
import 'package:jxmusic/services/local_music.dart';

/// 解密编排缓存层单测（ADR-004 v1.0 D3 / 评审 R-2/R-5/R-11/R-12）：
/// - 缓存布局 `<keyHex>/data.<ext>`、键 `sha1('v1|abs|size|mtimeMs')`；
/// - 命中缓存、key 变化重解、并发合并只解一次；
/// - 失败删除 `.part`、不缓存失败、修复后可重试；
/// - `playableUrl` 失败写 lastError；清理/淘汰/启动清理残留；
/// - 多目录扫描（R-6）、NCM 扫描读标签（AC-6）、解密后回填（R-17）。
void main() {
  late Directory tempDir;
  late Directory cacheRoot;
  late _FakeDecoder decoder;

  LocalFormatService newService({int? maxCacheFiles, int? maxCacheBytes}) {
    return LocalFormatService(
      decoders: <EncryptedAudioDecoder>[decoder],
      cacheRootProvider: () async => cacheRoot,
      tempRootProvider: () async => tempDir,
      maxCacheFiles: maxCacheFiles ?? LocalFormatService.defaultMaxCacheFiles,
      maxCacheBytes: maxCacheBytes ?? LocalFormatService.defaultMaxCacheBytes,
    );
  }

  File createSource(String name, {String content = 'ENCRYPTED-AUDIO-BYTES'}) {
    final file = File(p.join(tempDir.path, name));
    file.writeAsStringSync(content);
    return file;
  }

  Song songFor(String path) => Song(
    id: 'local_${path.hashCode.toRadixString(16)}',
    platform: JXPlatform.local,
    title: p.basenameWithoutExtension(path),
    artist: '未知歌手',
    audioUrl: path,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jx_format_test_');
    cacheRoot = Directory(p.join(tempDir.path, 'decrypted_audio'));
    decoder = _FakeDecoder();
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('扩展名识别与平台标签', () {
    test('加密/普通扩展名与平台标签', () {
      final service = newService();
      expect(service.isEncryptedPath('/x/a.ncm'), isTrue);
      expect(service.isEncryptedPath('/x/a.NCM'), isTrue);
      expect(service.isEncryptedPath('/x/a.qmcflac'), isTrue);
      expect(service.isEncryptedPath('/x/a.kgm'), isTrue);
      expect(
        service.isEncryptedPath('/x/a.kgg'),
        isTrue,
        reason: 'kgg 必须被识别（扫描可见 + 提示暂不支持，评审 R-16）',
      );
      expect(service.isEncryptedPath('/x/a.mp3'), isFalse);
      expect(service.isCommonPath('/x/a.mp3'), isTrue);

      expect(service.platformLabel('/x/a.ncm'), '网易云加密');
      expect(service.platformLabel('/x/a.mflac'), 'QQ加密');
      expect(service.platformLabel('/x/a.kgma'), '酷狗加密');
      expect(service.platformLabel('/x/a.kgg'), '酷狗加密');
      expect(service.platformLabel('/x/a.mp3'), isNull);

      expect(service.decoderForPath('/x/a.ncm'), same(decoder));
      expect(service.decoderForPath('/x/a.qmc0'), isNull);
    });
  });

  group('缓存键（R-2/R-12）', () {
    test('keyHex = sha1(v1|绝对路径|size|mtimeMs)', () {
      final source = createSource('key.ncm');
      final stat = source.statSync();
      final absolute = p.normalize(p.absolute(source.path));
      final expected = crypto.sha1
          .convert(
            utf8.encode(
              'v1|$absolute|${stat.size}|${stat.modified.millisecondsSinceEpoch}',
            ),
          )
          .toString();

      expect(
        LocalFormatService.cacheKeyFor(source.path, stat.size, stat.modified),
        expected,
      );
    });
  });

  group('ensureDecrypted：缓存布局/命中/重解', () {
    test('首次解密写入 <keyHex>/data.<ext>，二次命中不再解密', () async {
      final service = newService();
      final source = createSource('song.ncm');

      final key = LocalFormatService.cacheKeyFor(
        source.path,
        source.statSync().size,
        source.statSync().modified,
      );
      final progress = <double>[];
      final first = await service.ensureDecrypted(
        songFor(source.path),
        onProgress: progress.add,
      );

      expect(decoder.decodeCalls, 1);
      expect(first.existsSync(), isTrue);
      expect(
        first.path,
        p.join(cacheRoot.path, key, 'data.mp3'),
        reason: '缓存布局必须是 <keyHex>/data.<输出扩展名>',
      );
      expect(first.readAsStringSync(), 'FAKE-AUDIO-DATA');
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0, reason: '完成必须回调 1.0');
      await _expectNoPartFiles(cacheRoot);

      final second = await service.ensureDecrypted(songFor(source.path));
      expect(decoder.decodeCalls, 1, reason: '二次请求应命中缓存');
      expect(second.path, first.path);
      expect(await service.cacheFileCount(), 1);
      expect(await service.cacheSizeBytes(), 'FAKE-AUDIO-DATA'.length);
    });

    test('源文件 size/mtime 变化 -> key 变化 -> 重新解密成新缓存', () async {
      final service = newService();
      final source = createSource('changing.ncm', content: 'A');

      final first = await service.ensureDecrypted(songFor(source.path));
      expect(decoder.decodeCalls, 1);

      // 修改源文件（size 变化）应生成新 key，不能命中旧缓存
      source.writeAsStringSync('CHANGED-CONTENT');
      final second = await service.ensureDecrypted(songFor(source.path));
      expect(decoder.decodeCalls, 2, reason: '源文件变化后 key 变化必须重新解密');
      expect(second.path, isNot(first.path));
    });

    test('解码器输出扩展名以 decodeTo 返回值为准（多格式解码器）', () async {
      decoder = _FakeDecoder(outputExt: 'flac');
      final service = newService();
      final source = createSource('multi.ncm', content: 'MULTI-FORMAT');

      final file = await service.ensureDecrypted(songFor(source.path));
      expect(file.path.endsWith('data.flac'), isTrue);
    });
  });

  group('并发合并（R-5）', () {
    test('同一文件并发请求只解密一次，复用同一 Future/缓存文件', () async {
      decoder = _FakeDecoder()..delay = const Duration(milliseconds: 60);
      final service = newService();
      final source = createSource('concurrent.ncm');
      final song = songFor(source.path);

      final f1 = service.ensureDecrypted(song);
      final f2 = service.ensureDecrypted(song);
      final f3 = service.ensureDecrypted(song);
      final results = await Future.wait(<Future<File>>[f1, f2, f3]);

      expect(decoder.decodeCalls, 1, reason: '并发同 key 必须合并为一次解密');
      expect(results.map((f) => f.path).toSet().length, 1);
      expect(results.first.readAsStringSync(), 'FAKE-AUDIO-DATA');
    });
  });

  group('失败原子性（R-5/R-12）', () {
    test('解密失败：抛中文 FormatDecodeException、无 .part 残留、修复后可重试', () async {
      decoder.fail = true;
      final service = newService();
      final source = createSource('broken.ncm');

      await expectLater(
        service.ensureDecrypted(songFor(source.path)),
        throwsA(
          isA<FormatDecodeException>().having(
            (e) => e.message,
            'message',
            contains('文件不完整'),
          ),
        ),
      );
      expect(decoder.decodeCalls, 1);
      await _expectNoPartFiles(cacheRoot);
      expect(await service.cacheFileCount(), 0, reason: '失败产物不得留在缓存里');

      // 失败 Future 不得被永久缓存：修复后重试应再次调用解码器并成功
      decoder.fail = false;
      final retried = await service.ensureDecrypted(songFor(source.path));
      expect(decoder.decodeCalls, 2, reason: '失败后重试必须重新解密');
      expect(retried.existsSync(), isTrue);
      expect(await service.cacheFileCount(), 1);
    });

    test('解码器没有写输出文件：按失败处理并清理', () async {
      decoder.writeOutput = false;
      final service = newService();
      final source = createSource('empty-output.ncm');

      await expectLater(
        service.ensureDecrypted(songFor(source.path)),
        throwsA(isA<FormatDecodeException>()),
      );
      await _expectNoPartFiles(cacheRoot);
    });
  });

  group('playableUrl / lastError（R-11）', () {
    test('普通格式原样返回源路径；加密成功返回缓存路径且清空 lastError', () async {
      final service = newService();
      final mp3 = createSource('plain.mp3');
      expect(await service.playableUrl(songFor(mp3.path)), mp3.path);
      expect(service.lastError, isNull);

      final ncm = createSource('play.ncm');
      final url = await service.playableUrl(songFor(ncm.path));
      expect(url, isNotNull);
      expect(url, endsWith('data.mp3'));
      expect(service.lastError, isNull);
    });

    test('加密失败返回 null 并写入中文 lastError', () async {
      decoder.fail = true;
      final service = newService();
      final ncm = createSource('fail.ncm');

      expect(await service.playableUrl(songFor(ncm.path)), isNull);
      expect(service.lastError, isNotNull);
      expect(
        service.lastError,
        contains('文件不完整'),
        reason: '队列懒解密失败必须可被 UI 读到中文原因',
      );
    });

    test('缺少源路径：null + 中文原因', () async {
      final service = newService();
      expect(
        await service.playableUrl(
          const Song(
            id: 'x',
            platform: JXPlatform.local,
            title: '无路径',
            artist: '未知歌手',
          ),
        ),
        isNull,
      );
      expect(service.lastError, contains('路径缺失'));
    });
  });

  group('缓存清理与淘汰（R-5/R-12）', () {
    test('clearCache 删除全部缓存并返回释放字节数', () async {
      final service = newService();
      final source = createSource('clear.ncm');
      await service.ensureDecrypted(songFor(source.path));
      expect(await service.cacheFileCount(), 1);

      final removed = await service.clearCache();
      expect(removed, greaterThan(0));
      expect(await service.cacheFileCount(), 0);
      expect(await service.cacheSizeBytes(), 0);
    });

    test('文件数超过上限时按最旧访问时间淘汰', () async {
      final service = newService(maxCacheFiles: 2);
      final songs = <Song>[];
      for (var i = 0; i < 3; i++) {
        final source = createSource('limit$i.ncm', content: 'CONTENT-$i');
        songs.add(songFor(source.path));
        await service.ensureDecrypted(songs.last);
        // 保证 mtime 有先后
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        await service.cacheFileCount(),
        lessThanOrEqualTo(2),
        reason: '缓存文件数上限 2 必须生效',
      );
      expect(await service.cacheSizeBytes(), greaterThan(0));
    });

    test('首次缓存访问清理异常退出的残留 .part 与空目录', () async {
      final emptyKeyDir = Directory(p.join(cacheRoot.path, 'deadbeef'));
      emptyKeyDir.createSync(recursive: true);
      final part = File(p.join(emptyKeyDir.path, 'data.mp3.part'));
      part.writeAsStringSync('HALF');
      final rootPart = File(p.join(cacheRoot.path, 'orphan.part'));
      rootPart.writeAsStringSync('HALF');

      final service = newService();
      expect(await service.cacheFileCount(), 0);

      expect(part.existsSync(), isFalse, reason: '启动清理必须删除残留 .part');
      expect(rootPart.existsSync(), isFalse);
      expect(emptyKeyDir.existsSync(), isFalse, reason: '空缓存目录应被清理');
    });
  });

  group('标签与封面', () {
    test('readTags 返回解码器标签；普通格式返回 null', () async {
      final service = newService();
      final tags = await service.readTags('/x/a.ncm');
      expect(tags?.title, '标签标题');
      expect(tags?.artist, '标签歌手');
      expect(tags?.album, '标签专辑');
      expect(await service.readTags('/x/a.mp3'), isNull);
    });

    test('saveCoverBytes 以 md5 命名落到 jxmusic_covers，重复字节复用同一文件', () async {
      final service = newService();
      final bytes = Uint8List.fromList(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        1,
        2,
        3,
      ]);

      final first = await service.saveCoverBytes(bytes);
      final second = await service.saveCoverBytes(bytes);
      expect(first, isNotNull);
      expect(first, second);
      expect(p.basename(first!).endsWith('.png'), isTrue);
      expect(File(first).existsSync(), isTrue);
      expect(
        p.dirname(first),
        p.join(tempDir.path, LocalFormatService.coverDirName),
      );
    });
  });

  group('R-18 文件名回退只填补缺失字段（PRD REQ-4 / AC-6）', () {
    test('标签命中时文件名不回退：title/artist 保留标签值', () {
      final merged = mergeFileNameFallback(
        baseName: '周杰伦 - 七里香',
        title: '标签标题',
        artist: '标签歌手',
        hasTagTitle: true,
        hasTagArtist: true,
      );
      expect(merged.title, '标签标题', reason: '标签 title 存在时不能被文件名覆盖');
      expect(merged.artist, '标签歌手', reason: '标签 artist 存在时不能被文件名覆盖');
    });

    test('标签缺失时才用文件名解析（title/artist 可分别回退）', () {
      final noTags = mergeFileNameFallback(
        baseName: '周杰伦 - 七里香',
        title: '周杰伦 - 七里香',
        artist: '未知歌手',
        hasTagTitle: false,
        hasTagArtist: false,
      );
      expect(noTags.title, '七里香');
      expect(noTags.artist, '周杰伦');

      // 只有 title 命中：title 保留标签值，artist 仍用文件名
      final titleOnly = mergeFileNameFallback(
        baseName: '周杰伦 - 七里香',
        title: '标签标题',
        artist: '未知歌手',
        hasTagTitle: true,
        hasTagArtist: false,
      );
      expect(titleOnly.title, '标签标题');
      expect(titleOnly.artist, '周杰伦');

      // 文件名没有「 - 」时保持原值
      final noSeparator = mergeFileNameFallback(
        baseName: '七里香',
        title: '七里香',
        artist: '未知歌手',
        hasTagTitle: false,
        hasTagArtist: false,
      );
      expect(noSeparator.title, '七里香');
      expect(noSeparator.artist, '未知歌手');
    });

    test('集成：普通格式有标签 + 文件名含「 - 」→ 保留标签值', () async {
      final file = _writeTaggedMp3(
        File(p.join(tempDir.path, '周杰伦 - 七里香.mp3')),
        title: '标签标题',
        artist: '标签歌手',
        album: '标签专辑',
      );

      final song = await LocalMusicService().songFromFile(file);
      expect(song.title, '标签标题');
      expect(song.artist, '标签歌手');
    });

    test('集成：普通格式无标签 + 文件名含「 - 」→ 按文件名解析', () async {
      final file = File(p.join(tempDir.path, '周杰伦 - 七里香.mp3'))
        ..writeAsStringSync('');

      final song = await LocalMusicService().songFromFile(file);
      expect(song.title, '七里香');
      expect(song.artist, '周杰伦');
    });

    test('集成：NCM 标签命中 + 文件名含「 - 」→ 保留标签值不覆盖', () async {
      final ncm = File(p.join(tempDir.path, '周杰伦 - 七里香.ncm'))
        ..writeAsStringSync('x');
      final service = LocalMusicService(formats: newService());

      final song = await service.songFromFile(ncm);
      expect(song.title, '标签标题', reason: 'NCM 有标签时标题不能用文件名覆盖（R-18）');
      expect(song.artist, '标签歌手');
    });
  });

  group('LocalMusicService 多目录扫描（R-6）', () {
    test('隐藏目录/Android/data/Android/obb 跳过，重复根目录按绝对路径去重，错误隔离', () async {
      final root = Directory(p.join(tempDir.path, 'scan_root'))
        ..createSync(recursive: true);
      final sub = Directory(p.join(root.path, 'sub'))
        ..createSync(recursive: true);
      final hidden = Directory(p.join(root.path, '.hidden'))
        ..createSync(recursive: true);
      final androidData = Directory(p.join(root.path, 'Android', 'data'))
        ..createSync(recursive: true);
      final androidObb = Directory(p.join(root.path, 'Android', 'obb'))
        ..createSync(recursive: true);
      File(p.join(root.path, 'a.mp3')).writeAsStringSync('');
      File(p.join(sub.path, 'b.flac')).writeAsStringSync('');
      File(p.join(hidden.path, 'c.mp3')).writeAsStringSync('');
      File(p.join(androidData.path, 'd.mp3')).writeAsStringSync('');
      File(p.join(androidObb.path, 'e.mp3')).writeAsStringSync('');

      final service = LocalMusicService();
      final progress = <int>[];
      final missing = p.join(tempDir.path, 'not_exists');
      final result = await service.scanDirectories(<String>[
        root.path,
        sub.path,
        missing,
      ], onProgress: progress.add);

      expect(result.songs.map((s) => p.basename(s.audioUrl!)).toSet(), <String>{
        'a.mp3',
        'b.flac',
      }, reason: 'Android/data、Android/obb、隐藏目录都应跳过；重复根目录去重');
      expect(result.errors.length, 1, reason: '不存在的目录产生一条错误，不影响其它目录');
      expect(result.errors.single.path, missing);
      expect(result.errors.single.message, contains('不存在'));
      expect(progress.last, 2, reason: '扫描结束回调最终已发现数');
    });

    test('NCM 扫描时直接读标签/封面；QMC 回退文件名解析', () async {
      final root = Directory(p.join(tempDir.path, 'tag_root'))
        ..createSync(recursive: true);
      final ncm = File(p.join(root.path, 'cloud.ncm'))..writeAsStringSync('x');
      File(p.join(root.path, '周杰伦 - 七里香.qmc0')).writeAsStringSync('x');

      final formats = newService();
      final service = LocalMusicService(formats: formats);
      final result = await service.scanDirectories(<String>[root.path]);

      expect(result.errors, isEmpty);
      expect(result.songs.length, 2);

      final ncmSong = result.songs.firstWhere((s) => s.audioUrl == ncm.path);
      expect(ncmSong.title, '标签标题');
      expect(ncmSong.artist, '标签歌手');
      expect(ncmSong.album, '标签专辑');
      expect(ncmSong.coverUrl, isNotEmpty, reason: 'NCM 扫描时应落盘封面');
      expect(ncmSong.audioUrl, ncm.path, reason: 'audioUrl 必须保留源文件路径');
      expect(formats.platformLabel(ncmSong.audioUrl!), '网易云加密');

      final qmcSong = result.songs.firstWhere(
        (s) => s.audioUrl!.endsWith('.qmc0'),
      );
      expect(qmcSong.title, '七里香', reason: 'QMC 扫描时回退文件名解析');
      expect(qmcSong.artist, '周杰伦');
    });

    test('enrichFromDecrypted 从解密产物回填标签且保留源文件路径（R-17）', () async {
      final service = LocalMusicService(formats: newService());
      final source = createSource('backfill.ncm');
      final decrypted = _writeTaggedMp3(
        File(p.join(tempDir.path, 'backfill.mp3')),
        title: '回填标题',
        artist: '回填歌手',
        album: '回填专辑',
      );

      final before = songFor(source.path);
      final enriched = await service.enrichFromDecrypted(before, decrypted);

      expect(enriched.title, '回填标题');
      expect(enriched.artist, '回填歌手');
      expect(enriched.album, '回填专辑');
      expect(
        enriched.audioUrl,
        before.audioUrl,
        reason: '回填只改展示字段，audioUrl 仍保留源文件路径',
      );
    });
  });
}

Future<void> _expectNoPartFiles(Directory root) async {
  if (!await root.exists()) return;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      expect(
        entity.path.endsWith('.part'),
        isFalse,
        reason: '不允许残留半截缓存文件：${entity.path}',
      );
    }
  }
}

/// 构造带 ID3v2.3 标签的最小 MP3（audio_metadata_reader 可按标签解析）。
File _writeTaggedMp3(
  File file, {
  required String title,
  required String artist,
  required String album,
}) {
  List<int> frame(String id, String text) {
    // ID3v2.3 编码 0x01 = UTF-16（带 BOM），保证中文可写
    final payload = <int>[0x01, 0xFF, 0xFE];
    for (final unit in text.codeUnits) {
      payload.add(unit & 0xFF);
      payload.add((unit >> 8) & 0xFF);
    }
    final size = payload.length;
    return <int>[
      ...latin1.encode(id),
      (size >> 24) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
      0,
      0,
      ...payload,
    ];
  }

  final frames = <int>[
    ...frame('TIT2', title),
    ...frame('TPE1', artist),
    ...frame('TALB', album),
  ];
  final size = frames.length;
  final header = <int>[
    0x49, 0x44, 0x33, // "ID3"
    0x03, 0x00, // v2.3
    0x00, // flags
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
  ];
  // 一帧 MPEG1 Layer III 头 + 填充，保证 MP3 解析器能继续解析
  final mpegFrame = <int>[0xFF, 0xFB, 0x90, 0x64, ...List<int>.filled(413, 0)];
  file.writeAsBytesSync(<int>[...header, ...frames, ...mpegFrame]);
  return file;
}

/// fake 解码器：可配置输出扩展名/失败/延迟，统计调用次数并记录进度。
class _FakeDecoder implements EncryptedAudioDecoder {
  _FakeDecoder({this.outputExt = 'mp3'});

  final String outputExt;
  bool fail = false;
  bool writeOutput = true;
  Duration delay = Duration.zero;
  int decodeCalls = 0;
  final List<double> progress = <double>[];

  EncryptedAudioTags get tags => EncryptedAudioTags(
    title: '标签标题',
    artist: '标签歌手',
    album: '标签专辑',
    coverBytes: Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, //
    ]),
  );

  @override
  Set<String> get sourceExtensions => <String>{'ncm'};

  @override
  String? get outputExtension => outputExt;

  @override
  Future<bool> canDecode(File file) async => true;

  @override
  Future<EncryptedAudioTags?> readTags(File file) async => tags;

  @override
  Future<String> decodeTo(
    File input,
    File outputFile, {
    void Function(double progress)? onProgress,
  }) async {
    decodeCalls++;
    onProgress?.call(0.3);
    progress.add(0.3);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (fail) {
      await outputFile.writeAsString('HALF');
      onProgress?.call(0.6);
      progress.add(0.6);
      throw const FormatDecodeException('解密失败：文件不完整或密钥损坏');
    }
    if (writeOutput) {
      await outputFile.writeAsString('FAKE-AUDIO-DATA');
    }
    onProgress?.call(1);
    progress.add(1);
    return outputExt;
  }
}
