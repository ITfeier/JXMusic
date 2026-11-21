import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/local_format_service.dart';
import 'package:jxmusic/services/local_formats/format_decoder.dart';
import 'package:jxmusic/services/local_music.dart';
import 'package:jxmusic/services/local_paths.dart';
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/local_page.dart';

/// 本地音乐页 widget 测试（PRD REQ-1/REQ-6/REQ-7，评审 R-7/R-16/R-17）：
/// - 空态文案；
/// - 加密标签（网易云/QQ/酷狗、需解密、kgg「暂不支持」）；
/// - 「播放全部」/点击加密歌曲的播放回调（注入 fake，不依赖 providers/playback）；
/// - 加密歌曲解密成功后回填标题并刷新列表；
/// - Android 未授权横幅 + 去授权后刷新。
///
/// 全部通过构造函数注入 fake 服务，不碰真实 Hive/文件系统/权限插件。
/// 「扫描目录」入口已移除：扫描由打开页面时的 autoScan 自动触发。
void main() {
  Future<void> pumpLocalPage(WidgetTester tester, LocalPage page) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    tester.view.padding = const FakeViewPadding(top: 72, bottom: 144);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildJXTheme(JXColors.primary, darkMode: false),
        home: Scaffold(body: page),
      ),
    );
    // 初始化是异步的（读目录配置 + autoScan 扫描），有限次 pump 等待完成
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
  }

  _FakeFormatService fakeFormat() => _FakeFormatService();

  testWidgets('空态：显示未发现音乐文件与支持的加密格式文案', (tester) async {
    final page = LocalPage(
      musicService: _FakeMusicService(songs: const <Song>[]),
      formatService: fakeFormat(),
      pathsStore: _FakePathsStore(<String>[p.join('D:', 'Music')]),
      autoScan: false,
      androidOverride: false,
    );

    await pumpLocalPage(tester, page);

    expect(find.textContaining('未发现音乐文件'), findsOneWidget);
    expect(find.textContaining('NCM/QMC/MFLAC/MGG/KGM/VPR'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '360x640dp 下不允许溢出');
  });

  testWidgets('扫描后：加密标签、kgg 暂不支持标签、播放全部回调原始队列/索引', (tester) async {
    final mp3Path = p.join('D:', 'Music', '晴天.mp3');
    final ncmPath = p.join('D:', 'Music', '七里香.ncm');
    final kggPath = p.join('D:', 'Music', '酷狗歌.kgg');
    final songs = <Song>[
      Song(
        id: 'local_1',
        platform: JXPlatform.local,
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        audioUrl: mp3Path,
      ),
      Song(
        id: 'local_2',
        platform: JXPlatform.local,
        title: '七里香',
        artist: '周杰伦',
        album: '七里香',
        audioUrl: ncmPath,
      ),
      Song(
        id: 'local_3',
        platform: JXPlatform.local,
        title: '酷狗歌',
        artist: '酷狗歌手',
        album: '酷狗专辑',
        audioUrl: kggPath,
      ),
    ];
    List<Song>? playedQueue;
    int? playedIndex;
    final page = LocalPage(
      musicService: _FakeMusicService(songs: songs),
      formatService: fakeFormat(),
      pathsStore: _FakePathsStore(<String>[p.join('D:', 'Music')]),
      autoScan: true,
      androidOverride: false,
      playQueue: (queue, index) {
        playedQueue = queue;
        playedIndex = index;
      },
    );

    await pumpLocalPage(tester, page);
    await tester.pumpAndSettle();
    expect(find.text('扫描目录'), findsNothing, reason: '「扫描目录」按钮已移除');

    expect(find.textContaining('网易云加密 · 需解密'), findsOneWidget);
    expect(find.textContaining('酷狗加密 · 暂不支持'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    expect(find.textContaining('共 3 首'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('播放全部'));
    await tester.pump();
    expect(playedIndex, 0);
    expect(playedQueue, isNotNull);
    expect(playedQueue!.length, 3);
    expect(
      playedQueue!.first.audioUrl,
      mp3Path,
      reason: '播放回调必须传原始列表与原始索引（audioUrl 保留源路径）',
    );
  });

  testWidgets('点击加密歌曲：先解密（带进度）成功后回填标签并刷新列表，再回调播放', (tester) async {
    final ncmPath = p.join('D:', 'Music', '加密歌.ncm');
    final sourceSong = Song(
      id: 'local_ncm',
      platform: JXPlatform.local,
      title: '加密歌',
      artist: '未知歌手',
      album: '',
      audioUrl: ncmPath,
    );
    final format = fakeFormat();
    final music = _FakeMusicService(songs: <Song>[sourceSong]);
    List<Song>? playedQueue;
    int? playedIndex;
    final page = LocalPage(
      musicService: music,
      formatService: format,
      pathsStore: _FakePathsStore(<String>[p.join('D:', 'Music')]),
      autoScan: true,
      androidOverride: false,
      playQueue: (queue, index) {
        playedQueue = queue;
        playedIndex = index;
      },
    );

    await pumpLocalPage(tester, page);
    await tester.pumpAndSettle();

    await tester.tap(find.text('加密歌'));
    await tester.pumpAndSettle();

    expect(format.decryptCalls, 1, reason: '点击加密歌曲必须先解密');
    expect(music.enrichCalls, 1, reason: '解密成功后回填标签（R-17）');
    expect(find.text('回填标题'), findsOneWidget, reason: '列表应刷新为回填后的标题');
    expect(playedIndex, 0);
    expect(playedQueue, isNotNull);
    expect(
      playedQueue!.single.audioUrl,
      ncmPath,
      reason: '播放回调传原始 Song（audioUrl 保留源路径，不传解密后的 Song）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击 kgg：列表标暂不支持，解密失败弹窗展示中文原因', (tester) async {
    final kggPath = p.join('D:', 'Music', '无解.kgg');
    final format = fakeFormat()
      ..decryptError = const FormatDecodeException('酷狗 KGG 格式需要客户端密钥，暂不支持离线解密');
    final page = LocalPage(
      musicService: _FakeMusicService(
        songs: <Song>[
          Song(
            id: 'local_kgg',
            platform: JXPlatform.local,
            title: '无解',
            artist: '酷狗歌手',
            audioUrl: kggPath,
          ),
        ],
      ),
      formatService: format,
      pathsStore: _FakePathsStore(<String>[p.join('D:', 'Music')]),
      autoScan: true,
      androidOverride: false,
    );

    await pumpLocalPage(tester, page);
    await tester.pumpAndSettle();

    expect(find.textContaining('暂不支持'), findsOneWidget);
    await tester.tap(find.text('无解'));
    await tester.pumpAndSettle();

    expect(find.text('无法播放'), findsOneWidget);
    expect(find.textContaining('客户端密钥'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android 未授权：显示所有文件访问横幅，去授权后刷新并自动扫描', (tester) async {
    var granted = false;
    final music = _FakeMusicService(songs: const <Song>[]);
    final page = LocalPage(
      musicService: music,
      formatService: fakeFormat(),
      pathsStore: _FakePathsStore(<String>[p.join('D:', 'Music')]),
      autoScan: false,
      androidOverride: true,
      permissionChecker: () async => granted,
      permissionRequester: () async {
        granted = true;
        return true;
      },
    );

    await pumpLocalPage(tester, page);

    expect(find.textContaining('所有文件访问'), findsOneWidget);
    expect(find.text('去授权'), findsOneWidget);

    await tester.tap(find.text('去授权'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('所有文件访问'),
      findsNothing,
      reason: '授权后横幅应刷新消失（onResume 复核语义）',
    );
    expect(music.scanCalls, 1, reason: '授权后应自动扫描已配置目录');
    expect(tester.takeException(), isNull);
  });
}

/// fake 目录配置：内存实现，不触碰 Hive。
class _FakePathsStore extends LocalPathsStore {
  _FakePathsStore(List<String> initial) : _paths = List<String>.of(initial);

  List<String> _paths;

  @override
  Future<List<String>> load() async => List<String>.of(_paths);

  @override
  Future<void> save(List<String> paths) async {
    _paths = List<String>.of(paths);
  }

  @override
  Future<List<String>> add(String path) async {
    if (!_paths.contains(path)) _paths.add(path);
    return List<String>.of(_paths);
  }

  @override
  Future<List<String>> remove(String path) async {
    _paths.remove(path);
    return List<String>.of(_paths);
  }

  @override
  Future<bool> contains(String path) async => _paths.contains(path);

  @override
  Future<List<String>> defaultCandidates() async => List<String>.of(_paths);
}

/// fake 扫描服务：返回固定歌曲，并记录 enrich 调用。
class _FakeMusicService extends LocalMusicService {
  _FakeMusicService({this.songs = const <Song>[]});

  final List<Song> songs;
  int scanCalls = 0;
  int enrichCalls = 0;

  @override
  Future<ScanResult> scanDirectories(
    List<String> paths, {
    void Function(int found)? onProgress,
  }) async {
    scanCalls++;
    if (songs.isNotEmpty) onProgress?.call(songs.length);
    return ScanResult(songs: List<Song>.of(songs));
  }

  @override
  Future<Song> enrichFromDecrypted(Song song, File decryptedFile) async {
    enrichCalls++;
    return song.copyWith(title: '回填标题', artist: '回填歌手', album: '回填专辑');
  }

  @override
  Future<List<String>> defaultScanPaths() async => const <String>[];
}

/// fake 解密服务：可配置失败原因；缓存统计返回固定值。
class _FakeFormatService extends LocalFormatService {
  _FakeFormatService() : super(decoders: const <EncryptedAudioDecoder>[]);

  int decryptCalls = 0;
  FormatDecodeException? decryptError;

  @override
  Future<File> ensureDecrypted(
    Song song, {
    void Function(double progress)? onProgress,
  }) async {
    decryptCalls++;
    onProgress?.call(0.4);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final error = decryptError;
    if (error != null) throw error;
    onProgress?.call(1);
    return File(song.audioUrl ?? '');
  }

  @override
  Future<int> cacheSizeBytes() async => 23 * 1024 * 1024;

  @override
  Future<int> cacheFileCount() async => 7;

  @override
  Future<int> clearCache({String? keepPath}) async => 0;
}
