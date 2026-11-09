import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/ui/home_page.dart';
import 'package:jxmusic/ui/layout.dart';

/// 首页「热歌榜 · 更多」回归测试（真机缺陷：点击「更多 ›」没有展开内容）。
///
/// 修复前：`JXSectionHeader(title: '热歌榜', onMore: _load)` 只是重新加载整个首页
/// （还会闪 loading），不是展开。修复后：内联展开/收起，展示该平台已缓存的
/// 全部 topSongs，不重新请求网络。
///
/// 全程不联网：fake 三平台各返回 20 首 topSongs；360x640dp 手机尺寸。
class _FakePlatformApi implements MusicPlatformApi {
  _FakePlatformApi(this.platform);

  @override
  final int platform;

  int topSongsCalls = 0;

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async {
    topSongsCalls++;
    return [
      for (var i = 1; i <= 20; i++)
        Song(
          id: '$platform-$i',
          platform: platform,
          title: '热歌-$platform-$i',
          artist: '歌手-$platform-$i',
        ),
    ];
  }

  @override
  Future<List<Playlist>> recommendPlaylists(
          {int page = 1, int size = 20}) async =>
      const [];

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
  void restoreSession(AccountSession? session) {}

  @override
  String? get lastError => null;
}

Future<List<_FakePlatformApi>> _pumpHome(WidgetTester tester) async {
  // 360x640dp @480dpi（真机手机尺寸）
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final apis = <_FakePlatformApi>[
    for (final platform in const [0, 1, 2]) _FakePlatformApi(platform),
  ];
  final hub = MusicApiHub();
  for (final api in apis) {
    hub.register(api);
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [musicHubProvider.overrideWithValue(hub)],
      child: const MaterialApp(home: Scaffold(body: HomePage())),
    ),
  );
  // 有限次 pump（同 test/home_page_loading_test.dart，不用 pumpAndSettle）
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return apis;
}

/// 「热歌榜」区块标题（页面上还有多个推荐歌单的「更多 ›」，必须按标题定位）
final Finder _rankHeader = find.byWidgetPredicate(
  (w) => w is JXSectionHeader && w.title == '热歌榜',
);

void main() {
  testWidgets('热歌榜「更多 ›」内联展开/收起：不重新请求、不闪 loading', (tester) async {
    final apis = await _pumpHome(tester);

    // 热歌榜在首屏下方：滚动到可见（CustomScrollView 的 sliver 懒构建）
    await tester.scrollUntilVisible(_rankHeader, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();

    // 初始折叠：默认只渲染 3 行（360dp 宽），第 4 首不在树里
    expect(find.text('热歌-0-3'), findsOneWidget);
    expect(find.text('热歌-0-4'), findsNothing,
        reason: '折叠时不应渲染第 4 首及以后');
    expect(find.descendant(of: _rankHeader, matching: find.text('更多 ›')),
        findsOneWidget);

    // 点击「更多 ›」→ 内联展开
    await tester.tap(
        find.descendant(of: _rankHeader, matching: find.text('更多 ›')));
    await tester.pump();

    expect(find.text('热歌-0-4'), findsOneWidget,
        reason: '展开后应显示该平台已加载的后续歌曲');
    expect(find.descendant(of: _rankHeader, matching: find.text('收起 ›')),
        findsOneWidget);
    // 展开是基于 _tops 缓存，不得再次请求 topSongs，也不得闪 loading
    for (final api in apis) {
      expect(api.topSongsCalls, 1, reason: '展开不得触发网络请求');
    }
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '展开不得重新加载首页（不闪 loading）');
    expect(tester.takeException(), isNull);

    // 再点「收起 ›」→ 恢复默认 3 行与「更多 ›」
    await tester.ensureVisible(_rankHeader);
    await tester.pump();
    await tester.tap(
        find.descendant(of: _rankHeader, matching: find.text('收起 ›')));
    await tester.pump();

    expect(find.text('热歌-0-4'), findsNothing, reason: '收起后应恢复默认行数');
    expect(find.descendant(of: _rankHeader, matching: find.text('更多 ›')),
        findsOneWidget);
  });
}
