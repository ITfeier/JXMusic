import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/library_store.dart';

void main() {
  late Directory tempDir;
  late Box<Map> historyBox;
  late Box<Map> playlistsBox;
  late DateTime clock;

  LibraryStore newStore() => LibraryStore(
        historyBox: historyBox,
        playlistsBox: playlistsBox,
        clock: () => clock,
      );

  const songA = Song(
    id: 'a',
    platform: JXPlatform.netease,
    title: '晴天',
    artist: '周杰伦',
    album: '叶惠美',
  );
  const songB = Song(
    id: 'b',
    platform: JXPlatform.kugou,
    title: '国际歌',
    artist: '群星',
  );

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('jxmusic_lib_test_');
    Hive.init(tempDir.path);
    historyBox = await Hive.openBox<Map>('test_history');
    playlistsBox = await Hive.openBox<Map>('test_playlists');
  });

  setUp(() async {
    await historyBox.clear();
    await playlistsBox.clear();
    clock = DateTime(2026, 1, 1, 10, 0, 0);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('播放历史：新记录在最前，同一首连播不重复', () {
    final store = newStore();
    store.addHistory(songA);
    clock = clock.add(const Duration(minutes: 1));
    store.addHistory(songB);
    expect(store.history.length, 2);
    expect(store.history.first.song.id, 'b');

    // 再播一遍 A：应当被提到最前而不是新增一条
    clock = clock.add(const Duration(minutes: 1));
    store.addHistory(songA);
    expect(store.history.length, 2);
    expect(store.history.first.song.id, 'a');
    expect(historyBox.length, 2);
  });
  test('播放历史：上限 maxHistory，超出丢弃最旧', () {
    final store = newStore();
    for (var i = 0; i < JXConstants.maxHistory + 5; i++) {
      clock = clock.add(const Duration(seconds: 1));
      store.addHistory(Song(
        id: 'song_$i',
        platform: JXPlatform.qq,
        title: '歌曲 $i',
        artist: '歌手',
      ));
    }
    expect(store.history.length, JXConstants.maxHistory);
    expect(historyBox.length, JXConstants.maxHistory);
    expect(store.history.first.song.id,
        'song_${JXConstants.maxHistory + 4}');
  });

  test('播放历史：持久化后重载可还原并可删除', () async {
    final store = newStore();
    store.addHistory(songA);
    clock = clock.add(const Duration(minutes: 1));
    store.addHistory(songB);

    final reloaded = newStore();
    expect(reloaded.history.length, 2);
    expect(reloaded.history.first.song.title, '国际歌');

    // 重载后按 entry 删除要能命中 Hive 里的同一条记录
    reloaded.removeHistory(reloaded.history.first);
    expect(reloaded.history.length, 1);
    expect(historyBox.length, 1);

    reloaded.clearHistory();
    expect(reloaded.history, isEmpty);
    expect(historyBox.length, 0);
  });

  test('收藏：切换收藏状态并持久化', () {
    final store = newStore();
    expect(store.isFavorite(songA), isFalse);
    expect(store.toggleFavorite(songA), isTrue);
    expect(store.isFavorite(songA), isTrue);
    expect(store.favorites.length, 1);
    expect(playlistsBox.length, 1);

    final reloaded = newStore();
    expect(reloaded.isFavorite(songA), isTrue);
    expect(reloaded.favorites.first.title, '晴天');

    expect(reloaded.toggleFavorite(songA), isFalse);
    expect(reloaded.favorites, isEmpty);
    expect(playlistsBox.length, 0);
  });

  test('自建歌单：创建/加歌去重/移除/重命名/删除', () {
    final store = newStore();
    final id = store.createPlaylist('通勤');
    expect(store.playlists.length, 1);
    expect(store.playlistById(id)?.name, '通勤');

    expect(store.addSongToPlaylist(id, songA), isTrue);
    expect(store.addSongToPlaylist(id, songA), isFalse, reason: '重复加歌应被拒绝');
    expect(store.addSongToPlaylist(id, songB), isTrue);
    expect(store.playlistById(id)?.songCount, 2);

    store.renamePlaylist(id, '通勤歌单');
    expect(store.playlistById(id)?.name, '通勤歌单');

    store.removeSongFromPlaylist(id, songA);
    expect(store.playlistById(id)?.songCount, 1);

    // 持久化后重载
    final reloaded = newStore();
    final restored = reloaded.playlistById(id);
    expect(restored, isNotNull);
    expect(restored!.name, '通勤歌单');
    expect(restored.songs.single.id, 'b');

    reloaded.deletePlaylist(id);
    expect(reloaded.playlists, isEmpty);
    expect(playlistsBox.length, 0);
  });

  test('自建歌单封面：创建带封面/重命名保留/持久化重载/旧存档无字段兜底', () {
    final store = newStore();
    final id = store.createPlaylist('导入歌单',
        coverUrl: 'https://c1.kgimg.com/custom/240/20200511/a.jpg');
    expect(store.playlistById(id)?.coverUrl,
        'https://c1.kgimg.com/custom/240/20200511/a.jpg');

    // 重命名不丢封面
    store.renamePlaylist(id, '改名');
    expect(store.playlistById(id)?.name, '改名');
    expect(store.playlistById(id)?.coverUrl, isNotEmpty);

    // 持久化重载
    final reloaded = newStore();
    expect(reloaded.playlistById(id)?.coverUrl,
        'https://c1.kgimg.com/custom/240/20200511/a.jpg');

    // 普通新建无封面 → 空串（UI 渐变占位）
    final id2 = store.createPlaylist('普通歌单');
    expect(store.playlistById(id2)?.coverUrl, '');

    // 旧存档（+34 前落库无 coverUrl 字段）重载兜底空串
    final raw = playlistsBox.get('p:$id');
    playlistsBox.put('p:$id',
        Map<String, dynamic>.from(raw ?? const {})..remove('coverUrl'));
    expect(newStore().playlistById(id)?.coverUrl, '');
  });

  test('本机收藏歌单：收藏/取消/同平台同 id 去重/持久化/重载排序', () {
    final store = newStore();
    const pl1 = Playlist(
        id: 'p1', platform: JXPlatform.qq, title: '歌单一', songCount: 10);
    const pl2 = Playlist(
        id: 'p2', platform: JXPlatform.netease, title: '歌单二', songCount: 20);

    expect(store.isCollected(pl1), isFalse);
    expect(store.toggleCollectedPlaylist(pl1), isTrue);
    clock = clock.add(const Duration(minutes: 1));
    expect(store.toggleCollectedPlaylist(pl2), isTrue);
    expect(store.collectedPlaylists.length, 2);
    expect(store.collectedPlaylists.first.title, '歌单二',
        reason: '最新收藏在最前');
    expect(playlistsBox.length, 2);

    // 同平台同 id 视为同一个歌单：再点一次 = 取消收藏
    const pl1Renamed = Playlist(
        id: 'p1', platform: JXPlatform.qq, title: '歌单一（改名）');
    expect(store.toggleCollectedPlaylist(pl1Renamed), isFalse,
        reason: '同平台同 id 已收藏，toggle 应执行取消');
    expect(store.collectedPlaylists.length, 1);

    // 持久化后重载：顺序与状态一致
    final reloaded = newStore();
    expect(reloaded.collectedPlaylists.length, 1);
    expect(reloaded.collectedPlaylists.first.title, '歌单二');
    expect(reloaded.isCollected(pl2), isTrue);
    expect(reloaded.isCollected(pl1), isFalse);

    expect(reloaded.toggleCollectedPlaylist(pl2), isFalse);
    expect(reloaded.collectedPlaylists, isEmpty);
    expect(playlistsBox.length, 0);
  });

  test('存档损坏时容错，不抛异常', () async {
    await historyBox.put('h:bad', {'song': '不是 Map', 'playedAt': 123});
    await playlistsBox.put('f:bad', {'song': 42});
    final store = newStore();
    expect(store.history, isEmpty);
    expect(store.favorites, isEmpty);
  });
}
