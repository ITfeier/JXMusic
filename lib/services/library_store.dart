import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../core/constants.dart';
import '../models/playlist.dart';
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
  static const String _collectedPrefix = 'c:';

  final Box<Map> _historyBox;
  final Box<Map> _playlistsBox;
  final DateTime Function() _now;

  final List<HistoryEntry> _history = [];
  final List<Song> _favorites = [];
  final List<UserPlaylist> _playlists = [];
  final List<Playlist> _collectedPlaylists = [];

  List<HistoryEntry> get history => List.unmodifiable(_history);
  List<Song> get favorites => List.unmodifiable(_favorites);
  List<UserPlaylist> get playlists => List.unmodifiable(_playlists);
  List<Playlist> get collectedPlaylists =>
      List.unmodifiable(_collectedPlaylists);

  String _historyKey(DateTime t) =>
      '$_historyPrefix${t.microsecondsSinceEpoch}';

  /// 持久化用的歌曲 JSON：在线平台的 CDN 直链有时效（几分钟到几小时），
  /// 落库的直链重播时必然过期、还会被当成"已解析"跳过重新解析（静默卡住），
  /// 因此非本地歌曲一律不存 audioUrl（本地歌曲的 audioUrl 是文件路径，必须保留）。
  static Map<String, dynamic> _songJsonForStorage(Song song) {
    final json = song.toJson();
    if (song.platform != JXPlatform.local) {
      json['audioUrl'] = null;
    }
    return json;
  }

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
      'song': _songJsonForStorage(song),
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
      'song': _songJsonForStorage(song),
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

  // ---------------- 本机收藏歌单 ----------------

  /// 歌单唯一键：同平台同 id 视为同一个歌单
  static String collectedKey(Playlist playlist) =>
      '$_collectedPrefix${playlist.platform}:${playlist.id}';

  bool isCollected(Playlist playlist) =>
      _collectedPlaylists.any((p) =>
          p.platform == playlist.platform && p.id == playlist.id);

  /// 收藏 / 取消收藏歌单（本机），返回切换后的状态
  bool toggleCollectedPlaylist(Playlist playlist) {
    final index = _collectedPlaylists.indexWhere(
        (p) => p.platform == playlist.platform && p.id == playlist.id);
    final key = collectedKey(playlist);
    if (index >= 0) {
      _collectedPlaylists.removeAt(index);
      _playlistsBox.delete(key);
      notifyListeners();
      return false;
    }
    _collectedPlaylists.insert(0, playlist);
    _playlistsBox.put(key, {
      'playlist': playlist.toJson(),
      'addedAt': _now().millisecondsSinceEpoch,
    });
    notifyListeners();
    return true;
  }

  // ---------------- 持久化 ----------------

  void _persistPlaylist(UserPlaylist playlist) {
    _playlistsBox.put('$_playlistPrefix${playlist.id}', {
      'id': playlist.id,
      'name': playlist.name,
      'createdAt': playlist.createdAt.millisecondsSinceEpoch,
      'songs': [for (final s in playlist.songs) _songJsonForStorage(s)],
    });
  }

  void _reload() {
    _history.clear();
    _favorites.clear();
    _favoriteAddedAt.clear();
    _playlists.clear();
    _collectedPlaylists.clear();
    _collectedAddedAt.clear();

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
        // 会话内收藏是新的在最前（insert(0)），重载后必须按 addedAt 降序
        // 恢复同样的顺序，否则重启后收藏列表顺序漂移。
        _favoriteAddedAt.add(((raw?['addedAt'] as num?)?.toInt() ?? 0));
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
      } else if (keyStr.startsWith(_collectedPrefix)) {
        final playlistRaw = raw?['playlist'];
        if (playlistRaw is! Map) continue;
        try {
          _collectedPlaylists.add(
              Playlist.fromJson(Map<String, dynamic>.from(playlistRaw)));
          _collectedAddedAt.add((raw?['addedAt'] as num?)?.toInt() ?? 0);
        } catch (_) {
          continue;
        }
      }
    }
    _playlists.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // 收藏按 addedAt 降序（最新收藏在前，与会话内 insert(0) 行为一致）
    if (_favorites.isNotEmpty) {
      final indexed = List<int>.generate(_favorites.length, (i) => i);
      indexed.sort((a, b) {
        final cmp = _favoriteAddedAt[b].compareTo(_favoriteAddedAt[a]);
        return cmp != 0 ? cmp : a.compareTo(b);
      });
      final songs = [for (final i in indexed) _favorites[i]];
      _favorites
        ..clear()
        ..addAll(songs);
    }

    // 收藏的歌单按 addedAt 降序（最新收藏在前，与会话内 insert(0) 行为一致）
    if (_collectedPlaylists.isNotEmpty) {
      final indexed =
          List<int>.generate(_collectedPlaylists.length, (i) => i);
      indexed.sort((a, b) {
        final cmp = _collectedAddedAt[b].compareTo(_collectedAddedAt[a]);
        return cmp != 0 ? cmp : a.compareTo(b);
      });
      final playlists = [for (final i in indexed) _collectedPlaylists[i]];
      _collectedPlaylists
        ..clear()
        ..addAll(playlists);
    }
  }

  final List<int> _favoriteAddedAt = <int>[];
  final List<int> _collectedAddedAt = <int>[];

  static Song? _songOf(Object? raw) {
    if (raw is! Map) return null;
    try {
      return Song.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }
}
