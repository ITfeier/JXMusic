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
import 'package:jxmusic/services/guess_you_like.dart';
import 'package:jxmusic/services/library_store.dart';
import 'package:jxmusic/ui/home_page.dart';

/// 首页「猜你喜欢」契约测试（历史口味派生 + 每日种子）。
///
/// 推荐链路：播放历史/收藏 -> [GuessYouLike.tasteArtists] 口味歌手 ->
/// 按歌手轮换平台搜索候选池（排除已听、去重）-> [GuessYouLike.picks]
/// 每日种子取样（日期种子 ×1000 + 「换一批」批次）。
///
/// 锁定回归点：
/// 1. 口味统计：历史 1 分/次、收藏 2 分/首，多歌手名拆分、群星过滤；
/// 2. 每日种子：同日同批次结果稳定；「换一批」批次 +1 换新一批，不重新搜索；
/// 3. 有历史时首页出现「猜你喜欢」区块，候选排除已听歌曲；
/// 4. 口味歌手按序轮换平台搜索（#1→QQ、#2→网易云、#3→酷狗…）；
/// 5. 无历史时区块整体隐藏。
///
/// 全程不联网：fake MusicPlatformApi 按关键词返回固定搜索结果；
/// 播放历史在 testWidgets 之外预写入 Hive box（避开 fake async 里的
/// Hive 写入管线卡死问题，见 test/user_playlists_test.dart 注释）。
class _FakeGuessApi extends MusicPlatformApi {
  _FakeGuessApi(this.platform, this.searchResults);

  @override
  final int platform;

  /// keyword -> 搜索结果
  final Map<String, List<Song>> searchResults;

  int searchCalls = 0;

  @override
  Future<List<Song>> searchSongs(String keyword,
      {int page = 1, int size = 30}) async {
    searchCalls++;
    return searchResults[keyword] ?? const [];
  }

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

void main() {
  late Directory hiveDir;
  late Box<Map> historyBox;

  setUpAll(() async {
    // 首页猜你喜欢读取 Hive 曲库做口味画像（LibraryStore 存档）
    hiveDir = await Directory.systemTemp.createTemp('jxmusic_guess_test');
    Hive.init(hiveDir.path);
    historyBox = await Hive.openBox<Map>(JXConstants.hiveBoxHistory);
    await Hive.openBox<Map>(JXConstants.hiveBoxPlaylists);
  });

  tearDownAll(() async {
    // 不 await Hive.close()：Hive 写入管线由 Timer/IO 事件驱动，fake async
    // 测试结束后不再推进，await close()/clear() 永不返回（进程挂死教训）。
    try {
      hiveDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 预写一条播放历史（真实异步，避开 testWidgets fake async 里的 Hive 写入）
  Future<void> putHistory(Song song, int micros) async {
    await historyBox.put('h:$micros', {
      'song': song.toJson(),
      'playedAt': micros,
    });
  }

  Future<void> pumpHome(WidgetTester tester, MusicApiHub hub) async {
    // 360x640dp 手机尺寸
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [musicHubProvider.overrideWithValue(hub)],
        child: const MaterialApp(home: Scaffold(body: HomePage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('GuessYouLike 纯逻辑', () {
    test('splitArtists：多歌手拆分 + 群星过滤', () {
      expect(GuessYouLike.splitArtists('周杰伦/费玉清'), ['周杰伦', '费玉清']);
      expect(GuessYouLike.splitArtists('周杰伦、林俊杰'), ['周杰伦', '林俊杰']);
      expect(GuessYouLike.splitArtists('A feat. B'), ['A', 'B']);
      expect(GuessYouLike.splitArtists('群星'), isEmpty);
      expect(GuessYouLike.splitArtists(''), isEmpty);
      expect(GuessYouLike.splitArtists('  '), isEmpty);
    });

    test('tasteArtists：历史 1 分/次、收藏 2 分/首，按得分降序', () {
      final history = [
        HistoryEntry(
            song: Song(id: 'a', platform: 0, title: 't', artist: '周杰伦'),
            playedAt: DateTime(2026, 1, 1)),
        HistoryEntry(
            song: Song(id: 'b', platform: 0, title: 't', artist: '周杰伦'),
            playedAt: DateTime(2026, 1, 2)),
        HistoryEntry(
            song: Song(id: 'c', platform: 0, title: 't', artist: '周杰伦'),
            playedAt: DateTime(2026, 1, 3)),
        HistoryEntry(
            song: Song(id: 'd', platform: 0, title: 't', artist: '林俊杰'),
            playedAt: DateTime(2026, 1, 4)),
      ];
      final favorites = [
        Song(id: 'e', platform: 0, title: 't', artist: '王菲'),
      ];
      // 周杰伦 3 分（历史×3）> 王菲 2 分（收藏×2）> 林俊杰 1 分（历史×1）
      expect(GuessYouLike.tasteArtists(history, favorites),
          ['周杰伦', '王菲', '林俊杰']);
    });

    test('dailySeed：同日相同、隔日不同', () {
      final a = DateTime(2026, 11, 17, 8, 0);
      final b = DateTime(2026, 11, 17, 23, 59);
      final c = DateTime(2026, 11, 18);
      expect(GuessYouLike.dailySeed(a), GuessYouLike.dailySeed(b));
      expect(GuessYouLike.dailySeed(a), isNot(GuessYouLike.dailySeed(c)));
    });

    test('dailyShuffle：同种子同顺序、元素守恒、不改原列表', () {
      final list = [for (var i = 0; i < 20; i++) i];
      final s1 = GuessYouLike.dailyShuffle(list, 42);
      final s2 = GuessYouLike.dailyShuffle(list, 42);
      expect(s1, s2, reason: '同一种子洗牌结果必须一致');
      expect(s1.toSet(), list.toSet(), reason: '洗牌不得增删元素');
      expect(list, [for (var i = 0; i < 20; i++) i],
          reason: '原列表不得被修改');
    });

    test('picks：空池返回空；上限 take 生效', () {
      expect(GuessYouLike.picks(const [], DateTime.now(), 0), isEmpty);
      final pool = [
        for (var i = 1; i <= 14; i++)
          Song(id: 'g$i', platform: 0, title: 't$i', artist: 'a'),
      ];
      expect(GuessYouLike.picks(pool, DateTime.now(), 0).length, 9);
    });
  });

  group('首页「猜你喜欢」区块', () {
    setUp(() async {
      // 每条用例独立的播放历史（真实异步清理，不碰 fake async）
      await historyBox.clear();
    });

    testWidgets('有历史时按口味出推荐：排除已听歌曲、歌手轮换平台搜索',
        (tester) async {
      // Hive 磁盘写入必须包在 tester.runAsync（真实事件循环）里：
      // testWidgets 的 fake async 不推进 IO 事件，await put 永不返回。
      // 历史：周杰伦 ×2（不同歌）、林俊杰 ×1
      await tester.runAsync(() async {
        await putHistory(
            Song(id: 'h1', platform: 0, title: '晴天', artist: '周杰伦'), 1000);
        await putHistory(
            Song(id: 'h2', platform: 0, title: '夜曲', artist: '周杰伦'), 2000);
        await putHistory(
            Song(id: 'h3', platform: 1, title: '江南', artist: '林俊杰'), 3000);
      });

      final qq = _FakeGuessApi(0, {
        '周杰伦': [
          Song(id: 'g1', platform: 0, title: '猜歌-QQ-1', artist: '周杰伦'),
          // 与历史 h1 同 globalId（0:h1）：已听过，必须被排除
          Song(id: 'h1', platform: 0, title: '晴天', artist: '周杰伦'),
          Song(id: 'g2', platform: 0, title: '猜歌-QQ-2', artist: '周杰伦'),
        ],
      });
      final netease = _FakeGuessApi(1, {
        '林俊杰': [
          Song(id: 'g3', platform: 1, title: '猜歌-网易-1', artist: '林俊杰'),
        ],
      });
      final kugou = _FakeGuessApi(2, {});
      final hub = MusicApiHub()
        ..register(qq)
        ..register(netease)
        ..register(kugou);
      await pumpHome(tester, hub);

      // 回归点：区块标题 + 卡片头部
      expect(find.text('猜你喜欢'), findsOneWidget);
      expect(find.text('根据你的口味每日推荐'), findsOneWidget);

      // 回归点：候选歌曲全部展示（池 ≤ 9 首），已听的「晴天」被排除
      expect(find.text('猜歌-QQ-1'), findsOneWidget);
      expect(find.text('猜歌-QQ-2'), findsOneWidget);
      expect(find.text('猜歌-网易-1'), findsOneWidget);
      expect(find.text('晴天'), findsNothing,
          reason: '已听过的歌不应再出现在猜你喜欢里');

      // 回归点：口味歌手按序轮换平台（周杰伦→QQ、林俊杰→网易云、酷狗不搜）
      expect(qq.searchCalls, 1);
      expect(netease.searchCalls, 1);
      expect(kugou.searchCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('「换一批」：批次种子变化换新歌，不重新搜索', (tester) async {
      // 历史：单一口味歌手「阿喵」；候选池 14 首 > 取样 9 首
      // （Hive 写入包 runAsync：fake async 不推进 IO，见上一用例注释）
      await tester.runAsync(() async {
        await putHistory(
            Song(id: 'h1', platform: 0, title: '老歌', artist: '阿喵'), 1000);
      });
      final candidates = [
        for (var i = 1; i <= 14; i++)
          Song(id: 'g$i', platform: 0, title: '喵曲-$i', artist: '阿喵'),
      ];
      final qq = _FakeGuessApi(0, {'阿喵': candidates});
      final hub = MusicApiHub()
        ..register(qq)
        ..register(_FakeGuessApi(1, {}))
        ..register(_FakeGuessApi(2, {}));
      await pumpHome(tester, hub);

      // 与 HomePage 相同的算法本地复算期望结果（池 = 搜索结果顺序）
      final now = DateTime.now();
      final batch0 =
          GuessYouLike.picks(candidates, now, 0).map((s) => s.title).toList();
      final batch1 =
          GuessYouLike.picks(candidates, now, 1).map((s) => s.title).toList();
      expect(batch0.length, 9);

      // 第一批：选中的 9 首全部展示
      for (final title in batch0) {
        expect(find.text(title), findsOneWidget);
      }

      // 点「换一批 ›」→ 批次 +1，展示第二批
      await tester.tap(find.text('换一批 ›'));
      await tester.pump();
      for (final title in batch1) {
        expect(find.text(title), findsOneWidget);
      }

      // 换一批只动种子，不重新搜索（候选池已缓存）
      expect(qq.searchCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无播放历史时区块整体隐藏', (tester) async {
      final hub = MusicApiHub()
        ..register(_FakeGuessApi(0, {
          '路人': [Song(id: 'x', platform: 0, title: '不该出现', artist: '路人')],
        }))
        ..register(_FakeGuessApi(1, {}))
        ..register(_FakeGuessApi(2, {}));
      await pumpHome(tester, hub);

      expect(find.text('猜你喜欢'), findsNothing);
      expect(find.text('换一批 ›'), findsNothing);
      expect(find.text('不该出现'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
