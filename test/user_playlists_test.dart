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
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/library_page.dart';
import 'package:jxmusic/ui/playlist_detail_page.dart';
import 'package:jxmusic/ui/playlist_row.dart';

/// 音乐库「平台收藏歌单 + 导入歌单」契约测试（todo#4）。
///
/// 锁定回归点：
/// 1. [parseJXPlaylistLink]：网易云（fragment 链接）/ QQ / 酷狗分享链接与
///    纯数字歌单 id 全部识别，垃圾输入返回 null；
/// 2. [MusicApiHub.userPlaylists]：三平台结果轮询交错（QQ/网易云/酷狗
///    A1,B1,C1,A2…），平台缺数据时其余平台自动补位；
/// 3. 音乐库一级「音乐 / 歌单 / 下载」三个等宽 tab，音乐内二级「收藏/历史」、
///    歌单内二级「收藏/创建」（2026-11-18 重排）；
/// 4. 歌单「收藏」二级聚合展示三平台登录账号歌单，点卡片进歌单详情；
/// 5. 未登录任何平台时歌单「收藏」二级给出登录引导文案，不白屏；
/// 6. 「导入歌单」：粘贴分享链接 → 拉取歌单歌曲 → 存为本地自建歌单。
///
/// 全程不联网：fake MusicPlatformApi 返回固定数据；播放器用
/// `PlayerService(initPlayer: false)`（不加载 libmpv）。
class _FakePlatformApi extends MusicPlatformApi {
  _FakePlatformApi(this.platform,
      {this.loggedIn = true, this.playlistCount = 2, this.sessionError});

  @override
  final int platform;

  /// 是否「已登录」：false 时 userPlaylists 返回空（模拟未登录降级）
  final bool loggedIn;

  /// 每平台返回的账号歌单数（验证交错补位时可各不相同）
  final int playlistCount;

  /// 非空时 userPlaylists 抛会话失效异常（模拟「已登录但平台拒绝会话」，
  /// 如 MUSIC_U 过期 / 酷狗 token 风控）
  final String? sessionError;

  @override
  Future<List<Playlist>> userPlaylists(
      {int page = 1, int size = 30}) async {
    if (sessionError != null) throw SessionExpiredException(sessionError!);
    if (!loggedIn) return const [];
    return [
      for (var i = 1; i <= playlistCount; i++)
        Playlist(
          id: 'up-$platform-$i',
          platform: platform,
          title: '我的歌单-$platform-$i',
          songCount: 10 * i,
        ),
    ];
  }

  /// 导入契约：只有网易云歌单 id=777 有歌，其他 id 一律空（验证失败提示）
  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
      {int page = 1, int size = 100}) async {
    if (playlist.id == '777') {
      return [
        Song(
            id: 'imp-1',
            platform: playlist.platform,
            title: '导入曲一',
            artist: '歌手A'),
        Song(
            id: 'imp-2',
            platform: playlist.platform,
            title: '导入曲二',
            artist: '歌手B'),
      ];
    }
    return const [];
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
  Future<List<Playlist>> recommendPlaylists(
          {int page = 1, int size = 20}) async =>
      const [];

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async =>
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

/// 确定性清空 SnackBar 队列并取消当前 SnackBar 的 4s 超时计时器。
///
/// SnackBar 的超时 Timer 在入场动画完成后才创建，等它自然超时的时序在
/// fake async 下对边界极其敏感（差一帧计时器就没触发，测试进程会因
/// pending timer 无法退出）；断言完 toast 可见后直接取消最稳。
void _dismissAllSnackbars(WidgetTester tester) {
  final messenger = tester.state<ScaffoldMessengerState>(
      find.byType(ScaffoldMessenger).first);
  messenger.clearSnackBars();
  messenger.removeCurrentSnackBar();
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    // LibraryPage 读 Hive（LibraryStore 存档）；纯 Dart Hive 即可
    hiveDir = await Directory.systemTemp.createTemp('jxmusic_user_pl_test');
    Hive.init(hiveDir.path);
    await Hive.openBox<Map>(JXConstants.hiveBoxHistory);
    await Hive.openBox<Map>(JXConstants.hiveBoxPlaylists);
  });

  tearDownAll(() async {
    // 注意：这里【不能】await Hive.close()。导入歌单用例在 testWidgets 的
    // fake async 里发起了 Hive 磁盘写入，其写入管线由 Timer/IO 事件驱动，
    // 测试结束后不再推进，Hive 串行写队列会卡住，await close()/clear()
    // 永不返回（曾导致整个测试进程挂死）。文件句柄随 isolate 销毁释放。
    try {
      hiveDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('parseJXPlaylistLink：分享链接 / 歌单 ID 解析', () {
    test('网易云：id 在 fragment 的 #/playlist?id=xxx 也能识别', () {
      final parsed = parseJXPlaylistLink(
          'https://music.163.com/#/playlist?id=123456&userid=1');
      expect(parsed, isNotNull);
      expect(parsed!.platform, JXPlatform.netease);
      expect(parsed.id, '123456');
    });

    test('网易云：m 页链接', () {
      final parsed =
          parseJXPlaylistLink('https://music.163.com/m/playlist?id=88888888');
      expect(parsed!.platform, JXPlatform.netease);
      expect(parsed.id, '88888888');
    });

    test('QQ 音乐：/n/ryqq/playlist/XXXX', () {
      final parsed = parseJXPlaylistLink(
          'https://y.qq.com/n/ryqq/playlist/7DWQmB0CgVT8ZU2u');
      expect(parsed!.platform, JXPlatform.qq);
      expect(parsed.id, '7DWQmB0CgVT8ZU2u');
    });

    test('酷狗：specialid 参数', () {
      final parsed =
          parseJXPlaylistLink('https://t1.kugou.com/xxx.html?specialid=66677');
      expect(parsed!.platform, JXPlatform.kugou);
      expect(parsed.id, '66677');
    });

    test('酷狗：m.kugou.com/songlist/gcid_XXX/ 路径形态（App 分享链接）', () {
      final parsed = parseJXPlaylistLink(
          'https://m.kugou.com/songlist/gcid_3zivrucnzoz01f/?src_cid=3zivrucnzoz01f');
      expect(parsed!.platform, JXPlatform.kugou);
      expect(parsed.id, '3zivrucnzoz01f');
    });

    test('酷狗：?global_collection_id= 字母数字 gcid 参数形态', () {
      final parsed = parseJXPlaylistLink(
          'https://t1.kugou.com/x.html?global_collection_id=3zivrucnzoz01f');
      expect(parsed!.platform, JXPlatform.kugou);
      expect(parsed.id, '3zivrucnzoz01f');
    });

    test('纯数字：按网易云歌单 id 处理', () {
      final parsed = parseJXPlaylistLink(' 123456789 ');
      expect(parsed!.platform, JXPlatform.netease);
      expect(parsed.id, '123456789');
    });

    test('垃圾输入返回 null', () {
      expect(parseJXPlaylistLink(''), isNull);
      expect(parseJXPlaylistLink('随便写点什么'), isNull);
      expect(parseJXPlaylistLink('https://example.com/foo'), isNull);
    });
  });

  group('MusicApiHub.userPlaylists：三平台轮询交错', () {
    test('A1,B1,C1,A2… 交错；平台数量不等时其余平台补位', () async {
      final hub = MusicApiHub()
        ..register(_FakePlatformApi(0, playlistCount: 2))
        ..register(_FakePlatformApi(1, playlistCount: 1))
        ..register(_FakePlatformApi(2, playlistCount: 3));
      final merged = await hub.userPlaylists();
      expect(merged.map((p) => p.title).toList(), [
        // QQ#1 → 网易云#1 → 酷狗#1 → QQ#2 → 酷狗#2 → 酷狗#3
        '我的歌单-0-1', '我的歌单-1-1', '我的歌单-2-1',
        '我的歌单-0-2', '我的歌单-2-2', '我的歌单-2-3',
      ]);
    });

    test('全部平台未登录：空结果', () async {
      final hub = MusicApiHub()
        ..register(_FakePlatformApi(0, loggedIn: false))
        ..register(_FakePlatformApi(1, loggedIn: false))
        ..register(_FakePlatformApi(2, loggedIn: false));
      expect(await hub.userPlaylists(), isEmpty);
    });

    test('userPlaylistsByPlatform：会话失效平台带 error，不影响其它平台', () async {
      final hub = MusicApiHub()
        ..register(_FakePlatformApi(0))
        ..register(_FakePlatformApi(1, sessionError: '登录已过期，请重新登录'))
        ..register(_FakePlatformApi(2, sessionError: '触发安全验证，请重新登录'));
      final byPlatform = await hub.userPlaylistsByPlatform();
      expect(byPlatform[0]!.playlists.length, 2, reason: '正常平台不受影响');
      expect(byPlatform[0]!.hasError, isFalse);
      expect(byPlatform[1]!.hasError, isTrue);
      expect(byPlatform[1]!.error, '登录已过期，请重新登录');
      expect(byPlatform[1]!.playlists, isEmpty);
      expect(byPlatform[2]!.error, '触发安全验证，请重新登录');
    });
  });

  group('音乐库页：收藏歌单 tab + 导入歌单', () {
    /// 三平台登录态覆盖：[loggedIn] 里的平台给假会话，其它平台未登录
    Future<ProviderContainer> pumpLibrary(
      WidgetTester tester, {
      required MusicApiHub hub,
      Set<int> loggedIn = const {JXPlatform.qq, JXPlatform.netease, JXPlatform.kugou},
    }) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer(overrides: [
        musicHubProvider.overrideWithValue(hub),
        playerServiceProvider
            .overrideWith((ref) => PlayerService(initPlayer: false)),
        for (final p in const [
          JXPlatform.qq,
          JXPlatform.netease,
          JXPlatform.kugou,
        ])
          accountProvider(p).overrideWith((ref) => AccountNotifier(
                p,
                loggedIn.contains(p)
                    ? AccountSession(
                        platform: p,
                        cookies: const {'MUSIC_U': 'fake'},
                        nickname: '用户$p',
                      )
                    : null,
              )),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildJXTheme(JXColors.primary, darkMode: false),
            home: const Scaffold(body: LibraryPage()),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    MusicApiHub loggedInHub() => MusicApiHub()
      ..register(_FakePlatformApi(0))
      ..register(_FakePlatformApi(1))
      ..register(_FakePlatformApi(2));

    testWidgets('一级三 tab + 音乐二级；歌单「收藏」聚合三平台并轮询交错；点卡片进歌单详情',
        (tester) async {
      await pumpLibrary(tester, hub: loggedInHub());

      // 回归点 3：一级「音乐 / 歌单 / 下载」一排三个；音乐二级「收藏/历史」
      expect(find.text('音乐'), findsOneWidget);
      expect(find.text('歌单'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.textContaining(RegExp('^收藏 ')), findsOneWidget);
      expect(find.textContaining(RegExp('^历史 ')), findsOneWidget);

      // 切到一级「歌单」→ 二级默认「收藏」→ 三平台账号歌单聚合
      await tester.tap(find.text('歌单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 回归点 4：三平台账号歌单聚合 + 交错顺序
      final cards = tester
          .widgetList<JXPlaylistCard>(find.byType(JXPlaylistCard))
          .toList();
      expect(cards.length, 6, reason: '三个平台各 2 个账号歌单，应全部展示');
      final titles = cards.map((c) => c.playlist.title).toList();
      expect(titles, [
        for (var i = 1; i <= 2; i++)
          for (final p in const [0, 1, 2]) '我的歌单-$p-$i',
      ], reason: '收藏歌单必须按 QQ/网易云/酷狗 轮询交错排列');

      // 点第一张卡片进入歌单详情
      await tester.tap(find.text('我的歌单-0-1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlaylistDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未登录任何平台：状态 chip 标「未登录」+ 引导文案，不白屏',
        (tester) async {
      final hub = MusicApiHub()
        ..register(_FakePlatformApi(0, loggedIn: false))
        ..register(_FakePlatformApi(1, loggedIn: false))
        ..register(_FakePlatformApi(2, loggedIn: false));
      final container = await pumpLibrary(tester, hub: hub, loggedIn: const {});

      await tester.tap(find.text('歌单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 回归点：三个平台都显示「未登录」状态
      expect(
          find.text('QQ音乐 · 未登录'), findsOneWidget);
      expect(
          find.text('网易云音乐 · 未登录'), findsOneWidget);
      expect(
          find.text('酷狗音乐 · 未登录'), findsOneWidget);
      // 引导文案
      expect(find.textContaining('还没有收藏的歌单'), findsOneWidget);
      expect(find.textContaining('登录'), findsWidgets);
      // 未登录 chip 可点：直接跳设置页登录
      await tester.tap(find.text('网易云音乐 · 未登录'));
      await tester.pump();
      expect(container.read(navIndexProvider), 4,
          reason: '点未登录 chip 应跳到设置页');
      // 空态里的「去设置登录」按钮同样跳设置页
      container.read(navIndexProvider.notifier).state = 0;
      await tester.ensureVisible(find.text('去设置登录'));
      await tester.tap(find.text('去设置登录'));
      await tester.pump();
      expect(container.read(navIndexProvider), 4,
          reason: '点「去设置登录」应跳到设置页');
      expect(tester.takeException(), isNull);
    });

    testWidgets('部分登录：仅登录平台展示歌单，未登录平台状态可见', (tester) async {
      final hub = MusicApiHub()
        ..register(_FakePlatformApi(0))
        ..register(_FakePlatformApi(1, loggedIn: false))
        ..register(_FakePlatformApi(2, loggedIn: false));
      await pumpLibrary(tester,
          hub: hub, loggedIn: const {JXPlatform.qq});

      await tester.tap(find.text('歌单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // QQ 已登录：2 个歌单；网易/酷狗未登录
      expect(find.text('QQ音乐 · 2 个歌单'), findsOneWidget);
      expect(find.text('网易云音乐 · 未登录'), findsOneWidget);
      expect(find.text('酷狗音乐 · 未登录'), findsOneWidget);
      // 只有 QQ 的账号歌单卡片
      final cards = tester
          .widgetList<JXPlaylistCard>(find.byType(JXPlaylistCard))
          .toList();
      expect(cards.length, 2);
      expect(cards.every((c) => c.playlist.platform == JXPlatform.qq), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('会话失效：chip 展示真实错误（登录已过期）并跳设置重登',
        (tester) async {
      final hub = MusicApiHub()
        ..register(_FakePlatformApi(0))
        ..register(_FakePlatformApi(1, sessionError: '登录已过期，请重新登录'))
        ..register(_FakePlatformApi(2, sessionError: '登录已过期，请重新登录'));
      final container = await pumpLibrary(tester, hub: hub);

      await tester.tap(find.text('歌单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 真实设备诊断回归：网易云 MUSIC_U 过期、酷狗 token 失效时，
      // 不能再显示「0 个歌单」，要展示会话失效原因
      expect(find.text('QQ音乐 · 2 个歌单'), findsOneWidget);
      expect(find.text('网易云音乐 · 登录已过期，请重新登录'), findsOneWidget);
      expect(find.text('酷狗音乐 · 登录已过期，请重新登录'), findsOneWidget);
      // 失效 chip 可点：直接跳设置页重新登录
      await tester.tap(find.text('网易云音乐 · 登录已过期，请重新登录'));
      await tester.pump();
      expect(container.read(navIndexProvider), 4,
          reason: '点会话失效 chip 应跳到设置页重登');
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌单详情「收藏」：本机收藏展示在收藏歌单 tab，平台歌单去重',
        (tester) async {
      final container = await pumpLibrary(tester, hub: loggedInHub());
      final store = container.read(libraryProvider);
      expect(store.collectedPlaylists, isEmpty);

      // 进「收藏歌单」tab → 点第一张卡片进歌单详情
      await tester.tap(find.text('歌单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('我的歌单-0-1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlaylistDetailPage), findsOneWidget);

      // 点「收藏歌单」星标按钮 → 本机收藏 +1
      await tester.tap(find.byIcon(Icons.star_border_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.collectedPlaylists.length, 1);
      expect(store.collectedPlaylists.first.title, '我的歌单-0-1');
      // toast 在双层 Scaffold（透明路由）下会渲染两份文本，断言至少一份
      expect(find.textContaining('已收藏'), findsWidgets);
      // 收藏后星标变实心
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      _dismissAllSnackbars(tester);
      await tester.pumpAndSettle();

      // 返回收藏歌单 tab：本机收藏区块出现，且平台歌单里同一歌单去重
      // pop 转场 300ms，透明路由未退完时 AppBar 标题会和 tab 文本重名，
      // 必须等转场结束再断言。
      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('本机收藏 1'), findsOneWidget);
      final cards = tester
          .widgetList<JXPlaylistCard>(find.byType(JXPlaylistCard))
          .toList();
      expect(cards.length, 6,
          reason: '本机收藏 1 张 + 平台歌单 5 张（原 6 张去重 1 张）');
      expect(
          cards
              .where((c) => c.playlist.title == '我的歌单-0-1')
              .length,
          1,
          reason: '同一歌单不能既在本机收藏又在平台歌单重复出现');

      // 再进详情取消收藏 → 恢复
      await tester.tap(find.text('我的歌单-0-1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byIcon(Icons.star_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.collectedPlaylists, isEmpty);
      _dismissAllSnackbars(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    // 注意用例顺序：链接无效用例【必须】在成功导入用例之前声明。
    // 成功用例会在 fake async 里发起 Hive 磁盘写入（写入管线由 Timer/IO
    // 事件驱动，测试结束后不再推进，Hive 写队列随之卡住），之后任何对该
    // box 的 await（clear/close）都会永远不返回；无效用例不写数据，放前面
    // 才能在干净状态下读到「没有自建歌单」。
    testWidgets('导入歌单：链接无效（歌单为空）给出失败提示', (tester) async {
      final container =
          await pumpLibrary(tester, hub: loggedInHub());
      final store = container.read(libraryProvider);

      // 切到一级「歌单」→ 二级「创建」（导入/新建按钮在此）；360dp 窄屏下
      // 头部是图标按钮（Tooltip 保留文字语义）
      await tester.tap(find.text('歌单'));
      await tester.pump();
      await tester.tap(find.textContaining(RegExp('^创建 ')));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.download_rounded));
      await tester.pump();

      await tester.enterText(
          find.byType(TextField), 'https://music.163.com/#/playlist?id=999');
      await tester.tap(find.text('确定'));
      await tester.pump();

      // SnackBar 的 4s 超时计时器在入场动画完成后才创建：
      // 先 pump 过入场动画（计时器上膛），再跳过 4s 时长触发第一条退场，
      // pumpAndSettle 走完退场 + 第二条 toast 的入场
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('导入失败'), findsOneWidget, reason: '无效歌单 id 必须提示失败');
      expect(store.playlists, isEmpty, reason: '导入失败不应创建本地歌单');
      // 确定性清空 SnackBar 队列（取消 4s 计时器），避免遗留 pending timer
      _dismissAllSnackbars(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('导入歌单：粘贴网易云链接 → 拉取歌曲 → 存为本地自建歌单',
        (tester) async {
      final container =
          await pumpLibrary(tester, hub: loggedInHub());
      final store = container.read(libraryProvider);
      expect(store.playlists, isEmpty, reason: '测试前置：本地没有自建歌单');

      // 切到一级「歌单」→ 二级「创建」；360dp 窄屏下头部是图标按钮
      // （Tooltip 保留文字语义）
      await tester.tap(find.text('歌单'));
      await tester.pump();
      await tester.tap(find.textContaining(RegExp('^创建 ')));
      await tester.pump();
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.download_rounded));
      await tester.pump();

      // 第一步：粘贴网易云分享链接（id 在 fragment 里）
      await tester.enterText(find.byType(TextField),
          'https://music.163.com/#/playlist?id=777');
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 第二步：命名弹窗（title 与 hint 同为「歌单名称」，用 findsWidgets）
      expect(find.text('歌单名称'), findsWidgets);
      await tester.enterText(find.byType(TextField), '我的云村歌单');
      await tester.tap(find.text('确定'));
      await tester.pump();

      // 回归点 6：本地歌单已创建并写入 2 首导入歌曲
      expect(store.playlists.length, 1);
      final imported = store.playlists.first;
      expect(imported.name, '我的云村歌单');
      expect(imported.songs.length, 2);
      expect(imported.songs.map((s) => s.title).toList(),
          containsAll(['导入曲一', '导入曲二']));

      // SnackBar 的 4s 超时计时器在入场动画完成后才创建：先 pump 过入场动画
      // （计时器上膛），再跳过 4s 时长触发第一条退场，settle 后第二条 toast 可见
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.textContaining('已导入 2 首'), findsOneWidget);
      // 确定性清空 SnackBar 队列（取消 4s 计时器），避免遗留 pending timer
      _dismissAllSnackbars(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
