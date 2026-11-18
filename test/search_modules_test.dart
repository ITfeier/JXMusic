import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/album.dart';
import 'package:jxmusic/models/artist.dart';
import 'package:jxmusic/models/lyric_hit.dart';
import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/player_service.dart';
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/album_page.dart';
import 'package:jxmusic/ui/artist_page.dart';
import 'package:jxmusic/ui/playlist_detail_page.dart';
import 'package:jxmusic/ui/playlist_row.dart';
import 'package:jxmusic/ui/search_page.dart';

/// 搜索页「模块化聚合」契约测试：
/// 单曲 / 歌单 / 歌手 / 专辑 / 歌词 五个模块 tab，每个模块聚合三平台结果。
///
/// 锁定回归点：
/// 1. 五个模块 tab 齐全，切 tab 按需加载（不重复请求已加载模块）；
/// 2. 单曲：三平台结果合并去重（跨平台同名只一行）+ 音源标签；
/// 3. 歌单：三平台结果轮询交错，点卡片进入歌单详情；
/// 4. 歌手/专辑：点行进入歌手页/专辑页并加载歌曲；
/// 5. 歌词：展示命中片段；
/// 6. 空结果：每个模块给出明确文案，不白屏。
///
/// 全程不联网：fake MusicPlatformApi 返回固定数据；播放器用
/// `PlayerService(initPlayer: false)`（不加载 libmpv）。
/// 关键词「空空空」时所有模块返回空结果。
class _FakePlatformApi extends MusicPlatformApi {
  _FakePlatformApi(this.platform);

  @override
  final int platform;

  @override
  Future<List<Song>> searchSongs(String keyword,
      {int page = 1, int size = 30}) async {
    if (keyword == '空空空') return const [];
    return [
      Song(
        id: 's-$platform-1',
        platform: platform,
        title: '单曲-$platform-1',
        artist: '歌手甲',
      ),
      Song(
        id: 's-$platform-2',
        platform: platform,
        title: '单曲-$platform-2',
        artist: '歌手乙',
      ),
      // 三平台同名同歌手：验证跨平台合并去重
      Song(
        id: 'dupe-$platform',
        platform: platform,
        title: '晴天',
        artist: '周杰伦',
        // 网易云（platform=1）封面最完整 → 合并后的首选音源
        coverUrl: platform == 1 ? 'https://example.com/q.jpg' : '',
        duration: 200 + platform,
      ),
    ];
  }

  @override
  Future<List<Playlist>> searchPlaylists(String keyword,
      {int page = 1, int size = 30}) async {
    if (keyword == '空空空') return const [];
    return [
      for (var i = 1; i <= 2; i++)
        Playlist(
          id: 'pl-$platform-$i',
          platform: platform,
          title: '歌单-$platform-$i',
          songCount: 10 * i,
        ),
    ];
  }

  @override
  Future<List<Artist>> searchArtists(String keyword,
      {int page = 1, int size = 30}) async {
    if (keyword == '空空空') return const [];
    return [
      Artist(
        id: 'ar-$platform',
        platform: platform,
        name: '歌手$platform',
        songCount: 100 + platform,
        albumCount: 10 + platform,
      ),
    ];
  }

  @override
  Future<List<Album>> searchAlbums(String keyword,
      {int page = 1, int size = 30}) async {
    if (keyword == '空空空') return const [];
    return [
      Album(
        id: 'al-$platform',
        platform: platform,
        name: '专辑$platform',
        artist: '专辑歌手$platform',
        songCount: 8 + platform,
        publishTime: '2026-01-0${platform + 1}',
      ),
    ];
  }

  @override
  Future<List<LyricHit>> searchLyrics(String keyword,
      {int page = 1, int size = 30}) async {
    if (keyword == '空空空') return const [];
    return [
      LyricHit(
        song: Song(
          id: 'ly-$platform',
          platform: platform,
          title: '歌词曲$platform',
          artist: '词人$platform',
        ),
        snippet: '命中片段-$platform',
      ),
    ];
  }

  @override
  Future<List<Song>> artistSongs(Artist artist,
      {int page = 1, int size = 30}) async {
    return [
      for (var i = 1; i <= 2; i++)
        Song(
          id: 'as-$platform-$i',
          platform: artist.platform,
          title: '歌手歌曲$i',
          artist: artist.name,
        ),
    ];
  }

  @override
  Future<List<Song>> albumSongs(Album album,
      {int page = 1, int size = 30}) async {
    return [
      for (var i = 1; i <= 2; i++)
        Song(
          id: 'ab-$platform-$i',
          platform: album.platform,
          title: '专辑歌曲$i',
          artist: album.artist,
        ),
    ];
  }

  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
      {int page = 1, int size = 100}) async =>
      const [];

  @override
  Future<List<Playlist>> recommendPlaylists(
      {int page = 1, int size = 20}) async =>
      const [];

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async =>
      const [];

  @override
  Future<String?> getPlayUrl(Song song) async => null;

  @override
  Future<String> getLyrics(Song song) async => '';

  @override
  Future<({String qrUrl, String key})> createQrLogin() async =>
      (qrUrl: '', key: '');

  @override
  Future<AccountSession?> pollQrLogin(String key) async => null;

  @override
  void restoreSession(AccountSession? session) {}

  @override
  String? get lastError => null;
}

Future<void> _pumpSearch(WidgetTester tester) async {
  // 360x640dp 手机尺寸
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final hub = MusicApiHub();
  for (final platform in const [0, 1, 2]) {
    hub.register(_FakePlatformApi(platform));
  }
  final service = PlayerService(initPlayer: false);
  final container = ProviderContainer(overrides: [
    musicHubProvider.overrideWithValue(hub),
    playerServiceProvider.overrideWith((ref) => service),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildJXTheme(JXColors.primary, darkMode: false),
        home: const Scaffold(body: SearchPage()),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _searchKeyword(WidgetTester tester, String kw) async {
  await tester.enterText(find.byType(TextField), kw);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _switchTab(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(() async {
    // 歌单模块点卡片进 PlaylistDetailPage，详情页 watch libraryProvider
    // （收藏歌单星标），LibraryStore 构造需要 Hive box，先初始化。
    final dir =
        await Directory.systemTemp.createTemp('jxmusic_search_mod_test');
    Hive.init(dir.path);
    await Hive.openBox<Map>(JXConstants.hiveBoxHistory);
    await Hive.openBox<Map>(JXConstants.hiveBoxPlaylists);
  });

  testWidgets('五个模块 tab 齐全；单曲模块三平台合并去重 + 音源标签', (tester) async {
    await _pumpSearch(tester);

    // 回归点 1：五个模块 tab
    for (final name in const ['单曲', '歌单', '歌手', '专辑', '歌词']) {
      expect(find.text(name), findsOneWidget, reason: '缺少模块 tab「$name」');
    }

    await _searchKeyword(tester, '周杰伦');

    // 跨平台同名「晴天」合并为一行（初始视口内），首选音源 = 封面最完整的网易云
    expect(find.text('晴天'), findsOneWidget,
        reason: '跨平台同名歌曲必须去重合并成一行');
    expect(find.text('首选·网易云'), findsWidgets,
        reason: '网易云应为首选音源（封面最完整）');
    expect(find.text('QQ'), findsOneWidget);
    expect(find.text('酷狗'), findsOneWidget);

    // 懒加载列表：逐个滚动断言全部曲目（6 首平台独占 + 1 首三平台合并 = 7 行）
    final scrollable = find.byType(Scrollable).first;
    const expectedTitles = [
      '单曲-0-1', '单曲-0-2', '晴天',
      '单曲-1-1', '单曲-1-2',
      '单曲-2-1', '单曲-2-2',
    ];
    for (final t in expectedTitles) {
      await tester.scrollUntilVisible(find.text(t), 250,
          scrollable: scrollable);
      expect(find.text(t), findsOneWidget,
          reason: '单曲模块应聚合三平台结果（缺「$t」，或同名未去重出现多次）');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单模块：切 tab 自动加载、三平台轮询交错、点卡片进入歌单详情',
      (tester) async {
    await _pumpSearch(tester);
    await _searchKeyword(tester, '周杰伦');

    await _switchTab(tester, '歌单');

    // 回归点 3：交错顺序 QQ#1 → 网易云#1 → 酷狗#1 → QQ#2 …
    final cards =
        tester.widgetList<JXPlaylistCard>(find.byType(JXPlaylistCard)).toList();
    expect(cards, isNotEmpty);
    final titles = cards.map((c) => c.playlist.title).toList();
    final expected = <String>[
      for (var i = 1; i <= 2; i++)
        for (final p in const [0, 1, 2]) '歌单-$p-$i',
    ];
    expect(titles, expected.sublist(0, titles.length),
        reason: '歌单模块必须按 QQ/网易云/酷狗 轮询交错排列');

    // 点第一张卡片进入歌单详情
    await tester.tap(find.text('歌单-0-1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌手模块：三平台聚合，点歌手进入歌手页并加载热门歌曲', (tester) async {
    await _pumpSearch(tester);
    await _searchKeyword(tester, '周杰伦');

    await _switchTab(tester, '歌手');

    // 回归点 4：三平台歌手聚合
    expect(find.text('歌手0'), findsOneWidget);
    expect(find.text('歌手1'), findsOneWidget);
    expect(find.text('歌手2'), findsOneWidget);

    await tester.tap(find.text('歌手1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ArtistPage), findsOneWidget);
    expect(find.text('歌手歌曲1'), findsOneWidget);
    expect(find.text('歌手歌曲2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('专辑模块：点专辑进入专辑页并加载专辑歌曲', (tester) async {
    await _pumpSearch(tester);
    await _searchKeyword(tester, '周杰伦');

    await _switchTab(tester, '专辑');

    expect(find.text('专辑0'), findsOneWidget);
    expect(find.text('专辑1'), findsOneWidget);
    expect(find.text('专辑2'), findsOneWidget);

    await tester.tap(find.text('专辑2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AlbumPage), findsOneWidget);
    expect(find.text('专辑歌曲1'), findsOneWidget);
    expect(find.text('专辑歌曲2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌词模块：展示三平台命中片段', (tester) async {
    await _pumpSearch(tester);
    await _searchKeyword(tester, '周杰伦');

    await _switchTab(tester, '歌词');

    // 回归点 5：命中歌曲 + 片段
    expect(find.text('歌词曲0'), findsOneWidget);
    expect(find.text('歌词曲1'), findsOneWidget);
    expect(find.text('歌词曲2'), findsOneWidget);
    expect(find.text('命中片段-0'), findsOneWidget);
    expect(find.text('命中片段-1'), findsOneWidget);
    expect(find.text('命中片段-2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空结果：各模块给出明确提示，不白屏', (tester) async {
    await _pumpSearch(tester);
    await _searchKeyword(tester, '空空空');

    // 回归点 6：单曲空提示
    expect(find.text('三个平台都没有返回结果，请换个关键词或检查网络'),
        findsOneWidget);

    await _switchTab(tester, '歌单');
    expect(find.text('没有找到相关歌单，请换个关键词或检查网络'), findsOneWidget);

    await _switchTab(tester, '歌手');
    expect(find.text('没有找到相关歌手，请换个关键词或检查网络'), findsOneWidget);

    await _switchTab(tester, '专辑');
    expect(find.text('没有找到相关专辑，请换个关键词或检查网络'), findsOneWidget);

    await _switchTab(tester, '歌词');
    expect(find.text('没有找到相关歌词，请换个关键词或检查网络'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
