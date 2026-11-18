import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/player_service.dart';
import 'package:jxmusic/ui/playlist_detail_page.dart';
import 'package:jxmusic/ui/playlist_list_page.dart';

/// 假平台：按 page 返回预设歌单，记录每页请求次数与失败开关。
class _FakePlaylistApi extends MusicPlatformApi {
  _FakePlaylistApi({Map<int, List<Playlist>>? pages, this.failFirst = false})
      : pages = pages ?? {};

  @override
  int get platform => JXPlatform.qq;

  Map<int, List<Playlist>> pages;
  bool failFirst;
  final Map<int, int> pageCalls = {};
  int playlistSongsCalls = 0;

  @override
  Future<List<Playlist>> recommendPlaylists(
      {int page = 1, int size = 20}) async {
    pageCalls[page] = (pageCalls[page] ?? 0) + 1;
    if (failFirst && page == 1) throw Exception('模拟网络失败');
    return pages[page] ?? const [];
  }

  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
      {int page = 1, int size = 100}) async {
    playlistSongsCalls++;
    return const [];
  }

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async => const [];

  @override
  Future<List<Song>> searchSongs(String keyword,
          {int page = 1, int size = 30}) async =>
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
  Future<AccountSession?> loginByPassword(
          String username, String password) async =>
      null;

  @override
  Future<bool> sendSmsCode(String mobile) async => false;

  @override
  Future<AccountSession?> loginBySmsCode(String mobile, String code) async =>
      null;

  @override
  void restoreSession(AccountSession? session) {}

  @override
  String? get lastError => null;
}

List<Playlist> _makePlaylists(String prefix, int count) => [
      for (var i = 0; i < count; i++)
        Playlist(
          id: '$prefix-$i',
          platform: JXPlatform.qq,
          title: '$prefix-$i',
          creator: '测试',
          songCount: 10,
        ),
    ];

MusicApiHub _hub(MusicPlatformApi api) {
  final hub = MusicApiHub();
  hub.register(api);
  return hub;
}

/// 手机竖屏尺寸（420x800）：网格 3 列，首屏 20 张卡片会超出视口 → 可滚动分页。
void _usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _pumpPage(WidgetTester tester, MusicPlatformApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      // 详情页底部自带 PlayerBar（修复「整页路由盖住迷你播放条」），
      // 需要注入不加载 libmpv 的播放器；否则会去读未初始化的 Hive。
      overrides: [
        musicHubProvider.overrideWithValue(_hub(api)),
        playerServiceProvider
            .overrideWith((ref) => PlayerService(initPlayer: false)),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: const PlaylistListPage(platform: JXPlatform.qq),
      ),
    ),
  );
  // 首帧 + 完成首屏请求（不用 pumpAndSettle：加载态存在无限动画）
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() async {
    // PlaylistDetailPage 会 watch libraryProvider（收藏歌单星标），
    // LibraryStore 构造需要 Hive box，先初始化。
    final dir =
        await Directory.systemTemp.createTemp('jxmusic_pl_list_test');
    Hive.init(dir.path);
    await Hive.openBox<Map>(JXConstants.hiveBoxHistory);
    await Hive.openBox<Map>(JXConstants.hiveBoxPlaylists);
  });

  testWidgets('全部歌单页：首屏渲染 page1，滑到底自动加载 page2 并追加', (tester) async {
    _usePhoneSurface(tester);
    final api = _FakePlaylistApi(pages: {
      1: _makePlaylists('P1', 20),
      2: _makePlaylists('P2', 20),
      3: const [],
    });
    await _pumpPage(tester, api);

    // 标题与首屏卡片
    expect(find.text('QQ音乐 · 全部歌单'), findsOneWidget);
    expect(find.text('P1-0'), findsOneWidget);
    expect(api.pageCalls[1], 1);
    expect(api.pageCalls[2], isNull);

    // 滑到底 → 触发自动加载下一页
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(api.pageCalls[2], 1, reason: '滑到底应自动请求 page=2');
    expect(api.pageCalls[3], isNull);

    // 继续下滑即可看到第二批卡片（追加而非替换）
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump();
    expect(find.text('P2-0'), findsOneWidget);
  });

  testWidgets('全部歌单页：空态展示 + 点重试后加载成功', (tester) async {
    _usePhoneSurface(tester);
    final api = _FakePlaylistApi();
    await _pumpPage(tester, api);

    expect(find.text('暂无歌单'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    api.pages[1] = _makePlaylists('P1', 4);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('暂无歌单'), findsNothing);
    expect(find.text('P1-0'), findsOneWidget);
    // 返回条数 < 每页条数 → 直接进入「没有更多了」
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('全部歌单页：首屏失败展示错误 + 重试恢复', (tester) async {
    _usePhoneSurface(tester);
    final api = _FakePlaylistApi(failFirst: true);
    await _pumpPage(tester, api);

    expect(find.textContaining('加载失败'), findsOneWidget);

    api.failFirst = false;
    api.pages[1] = _makePlaylists('P1', 4);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('加载失败'), findsNothing);
    expect(find.text('P1-0'), findsOneWidget);
  });

  testWidgets('全部歌单页：点卡片进入 PlaylistDetailPage', (tester) async {
    _usePhoneSurface(tester);
    final api = _FakePlaylistApi(pages: {
      1: _makePlaylists('P1', 4),
    });
    await _pumpPage(tester, api);

    await tester.tap(find.text('P1-0'));
    await tester.pumpAndSettle();

    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(find.text('歌单详情'), findsOneWidget);
    expect(api.playlistSongsCalls, 1);
  });
}
