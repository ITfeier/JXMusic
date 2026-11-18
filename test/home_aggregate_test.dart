import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/ui/home_page.dart';
import 'package:jxmusic/ui/layout.dart';
import 'package:jxmusic/ui/playlist_hub_page.dart';
import 'package:jxmusic/ui/playlist_row.dart';

/// 首页「三平台歌单聚合」契约测试。
///
/// 聚合规则：QQ / 网易云 / 酷狗推荐歌单与热歌按轮询交错合并
/// （QQ#1、网易云#1、酷狗#1、QQ#2…），任何平台缺数据时其余平台自动补位。
///
/// 锁定回归点：
/// 1. 首页不再有三个分平台「推荐歌单」区块，只有一个聚合区块；
/// 2. 聚合歌单卡片顺序为轮询交错（懒加载横滑列表中已构建部分）；
/// 3. 「更多」进入 [PlaylistHubPage]（全部歌单 · 三平台），平台 pill 齐全。
class _FakePlatformApi extends MusicPlatformApi {
  _FakePlatformApi(this.platform);

  @override
  final int platform;

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async => const [];

  @override
  Future<List<Playlist>> recommendPlaylists(
      {int page = 1, int size = 20}) async {
    // 每平台 6 个可辨识歌单：歌单-{platform}-{i}
    return [
      for (var i = 1; i <= 6; i++)
        Playlist(
          id: '$platform-$i',
          platform: platform,
          title: '歌单-$platform-$i',
        ),
    ];
  }

  @override
  Future<List<Song>> searchSongs(String keyword,
          {int page = 1, int size = 30}) async =>
      const [];

  @override
  Future<String?> getPlayUrl(Song song) async => null;

  @override
  Future<String> getLyrics(Song song) async => '';

  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
          {int page = 1, int size = 100}) async =>
      const [];

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

Future<void> _pumpHome(WidgetTester tester) async {
  // 360x640dp 手机尺寸
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final hub = MusicApiHub();
  for (final platform in const [0, 1, 2]) {
    hub.register(_FakePlatformApi(platform));
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [musicHubProvider.overrideWithValue(hub)],
      child: const MaterialApp(home: Scaffold(body: HomePage())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('推荐歌单三平台轮询交错聚合，单一聚合区块', (tester) async {
    await _pumpHome(tester);

    // 回归点 1：只有「推荐歌单 · 三平台聚合」一个区块标题（旧版是
    // QQ/网易云/酷狗 三个「xx · 推荐歌单」区块）
    expect(find.text('推荐歌单 · 三平台聚合'), findsOneWidget);
    expect(find.textContaining('推荐歌单'), findsOneWidget);

    // 回归点 2：懒加载横滑列表中已构建卡片的顺序 = 轮询交错
    // （QQ#1 → 网易云#1 → 酷狗#1 → QQ#2 …）
    final cards = tester.widgetList<JXPlaylistCard>(
      find.byType(JXPlaylistCard),
    ).toList();
    expect(cards, isNotEmpty);
    final titles = cards.map((c) => c.playlist.title).toList();
    // 已构建部分必须严格落在交错序列的前缀上
    final expected = <String>[
      for (var i = 1; i <= 6; i++)
        for (final p in const [0, 1, 2]) '歌单-$p-$i',
    ];
    expect(titles, expected.sublist(0, titles.length),
        reason: '聚合歌单必须按 QQ/网易云/酷狗 轮询交错排列');

    // 三平台 #1 必须同屏出现（聚合的意义：一屏看全三平台）
    expect(find.text('歌单-0-1'), findsOneWidget);
    expect(find.text('歌单-1-1'), findsOneWidget);
    expect(find.text('歌单-2-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「更多」进入全部歌单聚合页（平台 pill 切换）', (tester) async {
    await _pumpHome(tester);

    // 点击聚合歌单区块（唯一「推荐歌单」标题）右侧的「更多 ›」
    final playlistHeader = find.byWidgetPredicate(
      (w) => w is JXSectionHeader && w.title == '推荐歌单 · 三平台聚合',
    );
    await tester
        .tap(find.descendant(of: playlistHeader, matching: find.text('更多 ›')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PlaylistHubPage), findsOneWidget);
    expect(find.text('全部歌单 · 三平台'), findsOneWidget);
    // 三个平台 pill 文案齐全
    expect(find.text('QQ音乐'), findsWidgets);
    expect(find.text('网易云'), findsWidgets);
    expect(find.text('酷狗'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
