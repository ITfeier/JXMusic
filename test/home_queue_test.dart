import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/player_service.dart';
import 'package:jxmusic/ui/home_page.dart';

/// 首页播放队列回归测试（真机反馈：从首页点歌，播放列表里只有点的那一首，
/// 只有从歌单详情点歌才会整单进队列）。
///
/// 修复前：首页 `_resolveAndPlay` 不传 queue，PlayerService.playSong 走
/// 单曲分支，队列里只有被点的那一首。
/// 修复后：首页热歌榜/猜你喜欢/「立即播放」都把所在列表整单作为队列传入。
///
/// fake 平台的 topSongs 自带 audioUrl（resolveAndPlay 跳过直链解析直接播放），
/// 播放器用 `PlayerService(initPlayer: false)`（不加载 libmpv）。
class _FakePlatformApi extends MusicPlatformApi {
  _FakePlatformApi(this.platform);

  @override
  final int platform;

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async => [
        for (var i = 1; i <= 20; i++)
          Song(
            id: '$platform-$i',
            platform: platform,
            title: '热歌-$platform-$i',
            artist: '歌手-$platform-$i',
            audioUrl: 'https://example.com/$platform-$i.mp3',
          ),
      ];

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

void main() {
  testWidgets('首页热歌榜点歌：整个聚合榜进队列，而不是只有点击的那一首',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final hub = MusicApiHub()
      ..register(_FakePlatformApi(0))
      ..register(_FakePlatformApi(1))
      ..register(_FakePlatformApi(2));
    final player = PlayerService(initPlayer: false);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicHubProvider.overrideWithValue(hub),
          playerServiceProvider.overrideWith((ref) => player),
        ],
        child: const MaterialApp(home: Scaffold(body: HomePage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 滚动到热歌榜（手机版聚合卡），点第一行
    await tester.scrollUntilVisible(
      find.text('热歌-0-1'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('热歌-0-1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(player.queue.length, 60,
        reason: '三平台各 20 首聚合榜应整单进队列');
    expect(player.currentSong?.title, '热歌-0-1');
    expect(player.currentIndex, 0);

    // 点另一行：队列不变，只是切到对应索引
    await tester.ensureVisible(find.text('热歌-1-1'));
    await tester.pump();
    await tester.tap(find.text('热歌-1-1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.queue.length, 60);
    expect(player.currentSong?.title, '热歌-1-1');
    expect(player.currentIndex, 1,
        reason: '热歌-1-1 是聚合榜交错序的第 2 首（索引 1）');
    expect(tester.takeException(), isNull);
  });
}
