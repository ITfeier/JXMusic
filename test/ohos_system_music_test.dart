import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/local_format_service.dart';
import 'package:jxmusic/services/local_formats/format_decoder.dart';
import 'package:jxmusic/services/local_music.dart';
import 'package:jxmusic/services/local_paths.dart';
import 'package:jxmusic/services/ohos_file_access.dart';
import 'package:jxmusic/services/ohos_system_music.dart';
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/local_page.dart';

/// 鸿蒙「系统音乐导入」测试：
/// - 记录序列化/URI 文件名解析；
/// - 服务：导入（标签解析/文件名回退/重复跳过/持久化失败不阻断）、
///   加载（激活授权）、移除（撤销授权）；
/// - 本地页（ohos 平台）：导入入口、导入后展示、长按移除；非 ohos 无入口。
void main() {
  final dir = Directory.systemTemp.createTempSync('jx_ohos_music_test');
  var boxSeq = 0;
  setUpAll(() {
    Hive.init(dir.path);
  });
  tearDownAll(() {
    dir.deleteSync(recursive: true);
  });

  Future<Box<dynamic>> openBox() async {
    final box = await Hive.openBox<dynamic>('settings_${boxSeq++}');
    addTearDown(() => box.deleteFromDisk());
    return box;
  }

  group('OhosSystemTrack', () {
    test('URI 文件名解析：URL 解码 + 去扩展名', () {
      const uri =
          'file://docs/storage/Users/currentUser/Music/'
          '%E5%91%A8%E6%9D%B0%E4%BC%A6%20-%20%E5%A4%9C%E6%9B%B2.mp3';
      expect(OhosSystemTrack.fileNameOf(uri), '周杰伦 - 夜曲');
    });

    test('toJson/fromJson 往返 + toSong 字段映射 + id 稳定', () {
      const track = OhosSystemTrack(
        uri: 'file://docs/storage/Users/currentUser/Music/a.flac',
        title: '夜曲',
        artist: '周杰伦',
        album: '十一月的萧邦',
        cover: '/cache/cover.jpg',
        duration: 226,
      );
      final restored = OhosSystemTrack.fromJson(track.toJson());
      expect(restored, isNotNull);
      expect(restored!.uri, track.uri);
      expect(restored.title, track.title);
      expect(restored.artist, track.artist);
      expect(restored.album, track.album);
      expect(restored.cover, track.cover);
      expect(restored.duration, track.duration);

      final song = track.toSong();
      expect(song.platform, JXPlatform.local);
      expect(song.audioUrl, track.uri);
      expect(song.duration, 226);
      // id 由 URI 决定：重启后重新加载同一条记录，id 不变（历史/收藏可回放）。
      expect(OhosSystemTrack.fromJson(track.toJson())!.toSong().id, song.id);
    });

    test('fromJson 容错：非 Map/缺 uri 返回 null，缺标题回退文件名', () {
      expect(OhosSystemTrack.fromJson(42), isNull);
      expect(OhosSystemTrack.fromJson(<String, dynamic>{}), isNull);
      final fallback = OhosSystemTrack.fromJson(
        <String, dynamic>{'uri': 'file://docs/x/abc.mp3'},
      );
      expect(fallback, isNotNull);
      expect(fallback!.title, 'abc');
      expect(fallback.artist, '未知歌手');
    });
  });

  group('OhosSystemMusicService', () {
    test('导入：解析标签落盘 + 持久化授权', () async {
      final box = await openBox();
      final access = _FakeOhosFileAccess(
        picked: const <String>[
          'file://docs/storage/Users/currentUser/Music/a.mp3',
          'file://docs/storage/Users/currentUser/Music/b.flac',
        ],
      );
      final service = OhosSystemMusicService(
        fileAccess: access,
        box: box,
        metadataParser: (uri) async => AudioMetadata(
          file: File(uri),
          title: '夜曲',
          artist: '周杰伦',
          album: '十一月的萧邦',
          duration: const Duration(seconds: 226),
        ),
      );

      var progressCalls = 0;
      final added = await service.importFromSystem(
        onProgress: (done, total) => progressCalls++,
      );

      expect(added, 2, reason: '两个新 URI 全部导入');
      expect(progressCalls, 2);
      expect(access.persisted.length, 2, reason: '导入时应对所选 URI 持久化授权');
      expect(service.storedCount, 2);

      final songs = await service.loadSongs();
      expect(songs.length, 2);
      expect(songs.first.title, '夜曲');
      expect(songs.first.artist, '周杰伦');
      expect(songs.first.album, '十一月的萧邦');
      expect(songs.first.duration, 226);
      expect(songs.first.audioUrl, access.picked.first);
      expect(access.activated, containsAll(access.picked));
    });

    test('导入：标签读不到回退「歌手 - 歌名」文件名', () async {
      final box = await openBox();
      final access = _FakeOhosFileAccess(
        picked: const <String>[
          'file://docs/storage/Users/currentUser/Music/'
          '%E5%91%A8%E6%9D%B0%E4%BC%A6%20-%20%E5%A4%9C%E6%9B%B2.mp3',
        ],
      );
      final service = OhosSystemMusicService(
        fileAccess: access,
        box: box,
        metadataParser: (_) async => null,
      );

      final added = await service.importFromSystem();

      expect(added, 1);
      final songs = await service.loadSongs();
      expect(songs.single.title, '夜曲');
      expect(songs.single.artist, '周杰伦');
    });

    test('导入：重复 URI 跳过，不产生重复记录', () async {
      final box = await openBox();
      const uri = 'file://docs/storage/Users/currentUser/Music/a.mp3';
      final access = _FakeOhosFileAccess(picked: const <String>[uri]);
      final service = OhosSystemMusicService(
        fileAccess: access,
        box: box,
        metadataParser: (_) async => null,
      );

      expect(await service.importFromSystem(), 1);
      access.picked = const <String>[uri];
      expect(await service.importFromSystem(), 0, reason: '第二次导入同文件应跳过');
      expect(await service.loadSongs(), hasLength(1));
    });

    test('导入：授权持久化失败不阻断（本次会话仍可播放）', () async {
      final box = await openBox();
      final access = _FakeOhosFileAccess(
        picked: const <String>['file://docs/storage/Users/currentUser/Music/a.mp3'],
      )..persistOk = false;
      final service = OhosSystemMusicService(
        fileAccess: access,
        box: box,
        metadataParser: (_) async => null,
      );

      expect(await service.importFromSystem(), 1);
      expect(await service.loadSongs(), hasLength(1));
    });

    test('导入：用户取消（选择器返回空）返回 0', () async {
      final box = await openBox();
      final service = OhosSystemMusicService(
        fileAccess: _FakeOhosFileAccess(picked: const <String>[]),
        box: box,
        metadataParser: (_) async => null,
      );
      expect(await service.importFromSystem(), 0);
      expect(service.storedCount, 0);
    });

    test('移除：删记录 + 撤销授权 + 返回剩余列表', () async {
      final box = await openBox();
      const uriA = 'file://docs/storage/Users/currentUser/Music/a.mp3';
      const uriB = 'file://docs/storage/Users/currentUser/Music/b.mp3';
      final access = _FakeOhosFileAccess(picked: const <String>[uriA, uriB]);
      final service = OhosSystemMusicService(
        fileAccess: access,
        box: box,
        metadataParser: (_) async => null,
      );
      await service.importFromSystem();
      final songs = await service.loadSongs();

      final remain = await service.removeSong(songs.first);

      expect(remain, hasLength(1));
      expect(remain.single.audioUrl, uriB);
      expect(access.revoked, contains(uriA));
      expect((await service.loadSongs()).single.audioUrl, uriB);
    });
  });

  group('LocalPage ohos 导入入口', () {
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
    }

    testWidgets('ohos：空态引导 + 导入后展示系统歌曲 + SnackBar 提示', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.ohos;
      try {
        final service = _FakeSystemMusicService();
        final page = LocalPage(
          musicService: _FakeMusicService(songs: const <Song>[]),
          formatService: _FakeFormatService(),
          pathsStore: _FakePathsStore(const <String>[]),
          systemMusicService: service,
          autoScan: false,
          androidOverride: false,
        );

        await pumpLocalPage(tester, page);

        expect(find.text('导入'), findsOneWidget);
        expect(find.textContaining('鸿蒙系统音乐导入'), findsOneWidget);
        expect(find.text('未发现音乐文件'), findsOneWidget);

        await tester.tap(find.text('导入'));
        await tester.pumpAndSettle();

        expect(service.importCalls, 1);
        expect(find.text('导入歌1'), findsOneWidget);
        expect(find.text('导入歌2'), findsOneWidget);
        expect(find.textContaining('已导入 2 首'), findsOneWidget);
        expect(find.textContaining('共 2 首'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        // addTearDown 晚于 binding 的 foundation 变量校验，必须在测试体内复位。
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('ohos：长按系统歌曲弹确认框，移除后列表刷新', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.ohos;
      try {
        final service = _FakeSystemMusicService();
        await service.importFromSystem();
        final page = LocalPage(
          musicService: _FakeMusicService(songs: const <Song>[]),
          formatService: _FakeFormatService(),
          pathsStore: _FakePathsStore(const <String>[]),
          systemMusicService: service,
          autoScan: false,
          androidOverride: false,
        );

        await pumpLocalPage(tester, page);
        expect(find.text('导入歌1'), findsOneWidget);

        await tester.longPress(find.text('导入歌1'));
        await tester.pumpAndSettle();
        expect(find.text('移除导入歌曲'), findsOneWidget);

        await tester.tap(find.text('移除'));
        await tester.pumpAndSettle();

        expect(service.removeCalls, 1);
        expect(find.text('导入歌1'), findsNothing);
        expect(find.text('导入歌2'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('非 ohos：不显示导入入口', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final page = LocalPage(
          musicService: _FakeMusicService(songs: const <Song>[]),
          formatService: _FakeFormatService(),
          pathsStore: _FakePathsStore(const <String>[]),
          autoScan: false,
          androidOverride: false,
        );

        await pumpLocalPage(tester, page);

        expect(find.text('导入'), findsNothing);
        expect(find.textContaining('鸿蒙系统音乐导入'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

/// fake 系统文件访问通道：记录授权调用，pick 返回预置列表。
class _FakeOhosFileAccess extends OhosFileAccess {
  _FakeOhosFileAccess({this.picked = const <String>[]});

  List<String> picked;
  bool persistOk = true;
  final List<String> persisted = <String>[];
  final List<String> activated = <String>[];
  final List<String> revoked = <String>[];

  @override
  Future<List<String>> pickAudioFiles() async => List<String>.of(picked);

  @override
  Future<bool> persistUris(List<String> uris) async {
    if (!persistOk) return false;
    persisted.addAll(uris);
    return true;
  }

  @override
  Future<bool> activateUris(List<String> uris) async {
    activated.addAll(uris);
    return true;
  }

  @override
  Future<bool> revokeUris(List<String> uris) async {
    revoked.addAll(uris);
    return true;
  }
}

/// fake 系统音乐服务：内存列表，import 追加两首固定歌曲。
class _FakeSystemMusicService extends OhosSystemMusicService {
  _FakeSystemMusicService() : super();

  final List<Song> _songs = <Song>[];
  int importCalls = 0;
  int removeCalls = 0;

  @override
  Future<int> importFromSystem({
    void Function(int done, int total)? onProgress,
  }) async {
    importCalls++;
    _songs
      ..add(
        Song(
          id: 'ohossys_1',
          platform: JXPlatform.local,
          title: '导入歌1',
          artist: '系统歌手',
          audioUrl: 'file://docs/storage/Users/currentUser/Music/1.mp3',
        ),
      )
      ..add(
        Song(
          id: 'ohossys_2',
          platform: JXPlatform.local,
          title: '导入歌2',
          artist: '系统歌手',
          audioUrl: 'file://docs/storage/Users/currentUser/Music/2.mp3',
        ),
      );
    onProgress?.call(2, 2);
    return 2;
  }

  @override
  Future<List<Song>> loadSongs() async => List<Song>.of(_songs);

  @override
  Future<List<Song>> removeSong(Song song) async {
    removeCalls++;
    _songs.removeWhere((s) => s.globalId == song.globalId);
    return List<Song>.of(_songs);
  }
}

/// fake 扫描服务：不扫描，返回空。
class _FakeMusicService extends LocalMusicService {
  _FakeMusicService({this.songs = const <Song>[]});

  final List<Song> songs;

  @override
  Future<ScanResult> scanDirectories(
    List<String> paths, {
    void Function(int found)? onProgress,
  }) async => ScanResult(songs: List<Song>.of(songs));
}

/// fake 解密服务：仅满足页面构造，解密相关路径不触发。
class _FakeFormatService extends LocalFormatService {
  _FakeFormatService() : super(decoders: const <EncryptedAudioDecoder>[]);
}

/// fake 目录配置：空目录。
class _FakePathsStore extends LocalPathsStore {
  _FakePathsStore(List<String> initial) : _paths = List<String>.of(initial);

  final List<String> _paths;

  @override
  Future<List<String>> load() async => List<String>.of(_paths);

  @override
  Future<List<String>> defaultCandidates() async => List<String>.of(_paths);
}
