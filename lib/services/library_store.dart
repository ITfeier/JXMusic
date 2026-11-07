import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../core/constants.dart';
import '../models/song.dart';

/// 一条播放历史
class HistoryEntry {
  final Song song;
  final DateTime playedAt;

  const HistoryEntry({required this.song, required this.playedAt});
}

/// 用户自建歌单
class UserPlaylist {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<Song> songs;

  const UserPlaylist({
    required this.id,
    required this.name,
    required this.createdAt,
    this.songs = const [],
  });

  int get songCount => songs.length;

  UserPlaylist copyWith({String? name, List<Song>? songs}) => UserPlaylist(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        songs: songs ?? this.songs,
      );
}

/// 本地曲库：播放历史 / 收藏 / 自建歌单，全部持久化在 Hive 里。
///
/// 存储约定（Box 泛型为 Map，按 key 前缀区分用途）：
/// - `h:<微秒>`  -> {song, playedAt}        播放历史，最多 [JXConstants.maxHistory] 条
/// - `f:<globalId>` -> {song, addedAt}      收藏
/// - `p:<id>`    -> {id, name, createdAt, songs[]}  自建歌单
class LibraryStore extends ChangeNotifier {
  LibraryStore({
    Box<Map>? historyBox,
    Box<Map>? playlistsBox,
    DateTime Function()? clock,
  })  : _historyBox = historyBox ?? Hive.box<Map>(JXConstants.hiveBoxHistory),
        _playlistsBox =
            playlistsBox ?? Hive.box<Map>(JXConstants.hiveBoxPlaylists),
        _now = clock ?? DateTime.now {
    _reload();
  }

  static const String _historyPrefix = 'h:';
  static const String _favoritePrefix = 'f:';
  static const String _playlistPrefix = 'p:';

  final Box<Map> _historyBox;
  final Box<Map> _playlistsBox;
  final DateTime Function() _now;

  final List<HistoryEntry> _history = [];
  final List<Song> _favorites = [];
  final List<UserPlaylist> _playlists = [];

  List<HistoryEntry> get history => List.unmodifiable(_history);
  List<Song> get favorites => List.unmodifiable(_favorites);
  List<UserPlaylist> get playlists => List.unmodifiable(_playlists);

  String _historyKey(DateTime t) =>
      '$_historyPrefix${t.microsecondsSinceEpoch}';

  // ---------------- 播放历史 ----------------

  /// 记录一次播放：同一首歌只保留一条（再次播放会提到最前并更新时间），
  /// 超出上限时丢弃最旧记录。
  void addHistory(Song song) {
    final existingIndex =
        _history.indexWhere((e) => e.song.globalId == song.globalId);
    if (existingIndex >= 0) {
      final old = _history.removeAt(existingIndex);
      _historyBox.delete(_historyKey(old.playedAt));
    }
    var now = _now();
    // 同一微秒内重复写入会让 key 冲突，顺延 1 微秒
    while (_historyBox.containsKey(_historyKey(now))) {
      now = now.add(const Duration(microseconds: 1));
    }
    _history.insert(0, HistoryEntry(song: song, playedAt: now));
    // 时间用微秒存，保证重启后能按 playedAt 还原出同样的 key
    _historyBox.put(_historyKey(now), {
      'song': song.toJson(),
      'playedAt': now.microsecondsSinceEpoch,
    });
    while (_history.length > JXConstants.maxHistory) {
      final old = _history.removeLast();
      _historyBox.delete(_historyKey(old.playedAt));
    }
    notifyListeners();
  }

  void removeHistory(HistoryEntry entry) {
    _history.removeWhere(
        (e) => e.song.globalId == entry.song.globalId &&
            e.playedAt == entry.playedAt);
    _historyBox.delete(_historyKey(entry.playedAt));
    notifyListeners();
  }

  void clearHistory() {
    // 逐条删除而不是 box.clear()：Hive 的 clear() 走异步批量后端，
    // 内存里的 length/key 更新会滞后一拍；逐条 delete 立即生效。
    for (final key in _historyBox.keys.toList()) {
      _historyBox.delete(key);
    }
    _history.clear();
    notifyListeners();
  }

  // ---------------- 收藏 ----------------

  bool isFavorite(Song song) =>
      _favorites.any((s) => s.globalId == song.globalId);

  /// 收藏 / 取消收藏，返回切换后的状态
  bool toggleFavorite(Song song) {
    final index = _favorites.indexWhere((s) => s.globalId == song.globalId);
    final key = '$_favoritePrefix${song.globalId}';
    if (index >= 0) {
      _favorites.removeAt(index);
      _playlistsBox.delete(key);
      notifyListeners();
      return false;
    }
    _favorites.insert(0, song);
    _playlistsBox.put(key, {
      'song': song.toJson(),
      'addedAt': _now().millisecondsSinceEpoch,
    });
    notifyListeners();
    return true;
  }

  // ---------------- 自建歌单 ----------------

  UserPlaylist? playlistById(String id) {
    for (final p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  String createPlaylist(String name) {
    final now = _now();
    final playlist = UserPlaylist(
      id: '${now.microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? '新建歌单' : name.trim(),
      createdAt: now,
    );
    _playlists.insert(0, playlist);
    _persistPlaylist(playlist);
    notifyListeners();
    return playlist.id;
  }

  void renamePlaylist(String id, String name) {
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index < 0) return;
    final renamed = _playlists[index].copyWith(
      name: name.trim().isEmpty ? _playlists[index].name : name.trim(),
    );
    _playlists[index] = renamed;
    _persistPlaylist(renamed);
    notifyListeners();
  }

  void deletePlaylist(String id) {
    _playlists.removeWhere((p) => p.id == id);
    _playlistsBox.delete('$_playlistPrefix$id');
    notifyListeners();
  }

  /// 加歌到歌单（同一首歌不重复加入），返回 false 表示已存在
  bool addSongToPlaylist(String id, Song song) {
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index < 0) return false;
    final playlist = _playlists[index];
    if (playlist.songs.any((s) => s.globalId == song.globalId)) return false;
    final updated = playlist.copyWith(songs: [...playlist.songs, song]);
    _playlists[index] = updated;
    _persistPlaylist(updated);
    notifyListeners();
    return true;
  }

  void removeSongFromPlaylist(String id, Song song) {
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index < 0) return;
    final playlist = _playlists[index];
    final updated = playlist.copyWith(
      songs: [
        for (final s in playlist.songs)
          if (s.globalId != song.globalId) s,
      ],
    );
    _playlists[index] = updated;
    _persistPlaylist(updated);
    notifyListeners();
  }

  // ---------------- 持久化 ----------------

  void _persistPlaylist(UserPlaylist playlist) {
    _playlistsBox.put('$_playlistPrefix${playlist.id}', {
      'id': playlist.id,
      'name': playlist.name,
      'createdAt': playlist.createdAt.millisecondsSinceEpoch,
      'songs': [for (final s in playlist.songs) s.toJson()],
    });
  }

  void _reload() {
    _history.clear();
    _favorites.clear();
    _playlists.clear();

    for (final key in _historyBox.keys) {
      final raw = _historyBox.get(key);
      final song = _songOf(raw?['song']);
      if (song == null) continue;
      final playedAt = (raw?['playedAt'] as num?)?.toInt() ?? 0;
      _history.add(HistoryEntry(
        song: song,
        playedAt: DateTime.fromMicrosecondsSinceEpoch(playedAt),
      ));
    }
    _history.sort((a, b) => b.playedAt.compareTo(a.playedAt));

    for (final key in _playlistsBox.keys) {
      final raw = _playlistsBox.get(key);
      final keyStr = key.toString();
      if (keyStr.startsWith(_favoritePrefix)) {
        final song = _songOf(raw?['song']);
        if (song == null) continue;
        _favorites.add(song);
      } else if (keyStr.startsWith(_playlistPrefix)) {
        final id = raw?['id'] as String? ?? '';
        if (id.isEmpty) continue;
        final songsRaw = raw?['songs'];
        final songs = <Song>[];
        if (songsRaw is List) {
          for (final s in songsRaw) {
            final song = _songOf(s);
            if (song != null) songs.add(song);
          }
        }
        _playlists.add(UserPlaylist(
          id: id,
          name: raw?['name'] as String? ?? '未命名歌单',
          createdAt: DateTime.fromMillisecondsSinceEpoch(
              (raw?['createdAt'] as num?)?.toInt() ?? 0),
          songs: songs,
        ));
      }
    }
    _playlists.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  static Song? _songOf(Object? raw) {
    if (raw is! Map) return null;
    try {
      return Song.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }
}
