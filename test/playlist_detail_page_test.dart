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
import 'package:jxmusic/ui/glass.dart' show GlassButton;
import 'package:jxmusic/ui/player/player_bar.dart';
import 'package:jxmusic/ui/playlist_detail_page.dart';

/// 歌单详情页回归测试（真机缺陷）：
/// 1) QQ 歌单详情头部原本写死 `playlist.songCount`，而 QQ 歌单广场接口不返回
///    歌曲数（恒 0），故永远显示「0 首」；修复后按实际加载首数显示。
/// 2) _songs 为空时正文全空白；修复后显示「该歌单暂无歌曲」+「重试」。
/// 3) 歌单详情是整页路由，会盖住 ShellPage 的迷你播放条；修复后本页底部
///    自带 PlayerBar（find.byType(PlayerBar)）。
///
/// 全程不联网：fake MusicPlatformApi 直接返回固定歌曲；播放器用
/// `PlayerService(initPlayer: false)`（不加载 libmpv），参照
/// test/player_page_layout_test.dart。360x640dp 下不允许 RenderFlex overflow。
const Playlist _qqPlaylist = Playlist(
  id: '7707261125',
  platform: JXPlatform.qq,
  title: '甜度爆表｜旋律说唱狙击少女心',
  creator: '我想要两颗西柚',
  // 真机现场：QQ 歌单广场接口不返回歌曲数，songCount 恒 0
  songCount: 0,
);

Song _song(int index, {bool vip = false}) => Song(
      id: 'song$index',
      platform: JXPlatform.qq,
      title: '歌曲$index',
      artist: '歌手$index',
      album: '专辑$index',
      vip: vip,
    );

/// 固定返回指定歌曲的 fake 平台实现（不联网）。
class _FakePlatformApi extends MusicPlatformApi {
  _FakePlatformApi({required this.songs, this.playUrlError});

  final List<Song> songs;

  /// getPlayUrl 失败（返回 null）时写入 lastError 的具体原因；null 则不写。
  final String? playUrlError;

  String? _lastError;
  int playlistSongsCalls = 0;

  @override
  int get platform => JXPlatform.qq;

  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
      {int page = 1, int size = 100}) async {
    playlistSongsCalls++;
    return songs;
  }

  @override
  Future<List<Song>> searchSongs(String keyword,
          {int page = 1, int size = 30}) async =>
      const [];

  @override
  Future<String?> getPlayUrl(Song song) async {
    _lastError = playUrlError;
    return null;
  }

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
  String? get lastError => _lastError;
}

Future<_FakePlatformApi> _pumpDetailPage(
  WidgetTester tester, {
  required List<Song> songs,
  String? playUrlError,
}) async {
  // 360x640dp @480dpi（含状态栏 24dp / 导航栏 48dp 安全区）
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3.0;
  tester.view.padding = const FakeViewPadding(top: 72, bottom: 144);
  addTearDown(tester.view.reset);

  final api = _FakePlatformApi(songs: songs, playUrlError: playUrlError);
  final hub = MusicApiHub()..register(api);
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
        home: const PlaylistDetailPage(playlist: _qqPlaylist),
      ),
    ),
  );
  // 有限次 pump：不联网但图片加载失败回调会调度 postFrame 重试（不用
  // pumpAndSettle，避免因图片重试/动画无限等待）。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return api;
}

void main() {
  setUpAll(() async {
    // PlaylistDetailPage 会 watch libraryProvider（收藏歌单星标），
    // LibraryStore 构造需要 Hive box，先初始化。
    final dir =
        await Directory.systemTemp.createTemp('jxmusic_pl_detail_test');
    Hive.init(dir.path);
    await Hive.openBox<Map>(JXConstants.hiveBoxHistory);
    await Hive.openBox<Map>(JXConstants.hiveBoxPlaylists);
  });

  testWidgets('QQ 歌单详情加载后按实际首数显示、底部有 PlayerBar、360x640 不溢出',
      (tester) async {
    final api = await _pumpDetailPage(
      tester,
      songs: [for (var i = 1; i <= 66; i++) _song(i)],
    );

    // 根因回归：头部不能再用写死的 songCount（QQ 歌单广场恒 0）
    expect(find.textContaining('66 首'), findsOneWidget,
        reason: '头部应显示实际加载首数，实际找到 ${find.textContaining('首').evaluate().length} 个含「首」文本');
    expect(find.textContaining('0 首'), findsNothing,
        reason: 'QQ 接口不返回歌曲数，不能再显示误导性的「0 首」');

    // 迷你播放条必须真正嵌入本页（整页路由盖住 ShellPage 导致过真机缺陷）
    expect(find.byType(PlayerBar), findsOneWidget);

    // 360x640dp 不允许溢出
    expect(tester.takeException(), isNull,
        reason: '360x640dp 下歌单详情页不允许 RenderFlex overflow');

    expect(api.playlistSongsCalls, 1, reason: '进入详情页只应请求一次歌单歌曲');
  });

  testWidgets('空歌单：显示「该歌单暂无歌曲」+「重试」，播放全部保持禁用', (tester) async {
    await _pumpDetailPage(tester, songs: const []);

    expect(find.text('该歌单暂无歌曲'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 空列表时「播放全部」必须禁用（onPressed == null）
    final playAll = tester.widget<GlassButton>(
      find.widgetWithText(GlassButton, '播放全部'),
    );
    expect(playAll.onPressed, isNull, reason: '空歌单时「播放全部」应保持禁用');

    // 仍保留底部迷你播放条，且不溢出
    expect(find.byType(PlayerBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登录点 VIP 歌：提示「需要先登录」而非笼统失败文案', (tester) async {
    await _pumpDetailPage(tester, songs: [_song(1, vip: true)]);

    await tester.tap(find.text('歌曲1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('需要先登录QQ音乐才能播放 VIP 音源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点歌失败：展示平台具体原因，不再误导「需要先在设置里登录」', (tester) async {
    await _pumpDetailPage(
      tester,
      songs: [_song(1)],
      playUrlError: '暂无可用音源（版权受限，QQ音乐）',
    );

    await tester.tap(find.text('歌曲1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 平台本次新增的具体原因必须进入提示
    expect(find.text('「歌曲1」无法播放：暂无可用音源（版权受限，QQ音乐）'),
        findsOneWidget);
    // 已登录/非 VIP 场景不允许再出现误导性的「先在设置里登录」
    expect(find.textContaining('需要先在设置里登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
