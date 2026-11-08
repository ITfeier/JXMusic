import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/ui/home_page.dart';

/// 空的平台实现：不联网、立即返回空数据，用于验证首页加载状态机。
///
/// 记录调用次数：若首页没有真正发起加载（例如日后误删 initState 里的
/// `_load()`），只断言「无 spinner + 出现标题」会误通过；调用计数把
/// 「首次进入确实请求了数据」也锁进回归。
class _FakePlatformApi implements MusicPlatformApi {
  _FakePlatformApi(this.platform);

  @override
  final int platform;

  int topSongsCalls = 0;
  int recommendCalls = 0;

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
      {int page = 1, int size = 20}) async {
    recommendCalls++;
    return const [];
  }

  @override
  Future<List<Song>> playlistSongs(Playlist playlist,
          {int page = 1, int size = 100}) async =>
      const [];

  @override
  Future<List<Song>> topSongs({int page = 1, int size = 30}) async {
    topSongsCalls++;
    return const [];
  }

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

MusicApiHub _fakeHub(List<_FakePlatformApi> apis) {
  final hub = MusicApiHub();
  for (final api in apis) {
    hub.register(api);
  }
  return hub;
}

void main() {
  testWidgets('首页首次进入会发起加载并退出 loading（防 0.9.3 永久转圈回归）',
      (tester) async {
    final apis = <_FakePlatformApi>[
      for (final platform in const [0, 1, 2]) _FakePlatformApi(platform),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [musicHubProvider.overrideWithValue(_fakeHub(apis))],
        child: const MaterialApp(home: Scaffold(body: HomePage())),
      ),
    );

    // 有界等待：不要用 pumpAndSettle——旧 bug 下 spinner 永远动画，会以
    // 10 分钟超时失败（CI 反馈极慢）；这里两次 pump 后直接断言，旧代码立即失败。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 回归点 1：修复前 `_loading` 初值为 true，_load 被守卫直接 return，
    // 永远停留在 CircularProgressIndicator；修复后必须消失并出现内容区。
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('推荐歌单'), findsWidgets);

    // 回归点 2：首页确实发起了加载（防止日后删掉 initState 里的 _load() 后误通过）。
    for (final api in apis) {
      expect(api.topSongsCalls, 1);
      expect(api.recommendCalls, 1);
    }
  });
}
