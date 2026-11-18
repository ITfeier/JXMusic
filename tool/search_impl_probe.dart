// 实现层探针：直接调用三平台 Api 的新分类搜索方法，验证字段映射是否正确。
// 仅开发期诊断，不进入应用构建。运行：
//   dart run tool/search_impl_probe.dart [netease|qq|kugou|all]
// ignore_for_file: avoid_print
import 'package:jxmusic/models/album.dart';
import 'package:jxmusic/models/artist.dart';
import 'package:jxmusic/models/lyric_hit.dart';
import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/qq_api.dart';

const kw = '周杰伦';

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'all' : args.first;
  if (mode == 'netease' || mode == 'all') await _check(NeteaseApi(), '网易云');
  if (mode == 'qq' || mode == 'all') await _check(QQMusicApi(), 'QQ');
  if (mode == 'kugou' || mode == 'all') await _check(KuGouApi(), '酷狗');
}

String _songLine(Song s) =>
    '${s.title} - ${s.artist} | album=${s.album} | id=${s.id} '
    'dur=${s.duration} vip=${s.vip} cover=${s.coverUrl.isEmpty ? '(空)' : '有'}';

Future<void> _check(MusicPlatformApi api, String name) async {
  print('===== $name =====');
  try {
    final List<Playlist> playlists = await api.searchPlaylists(kw, size: 3);
    print('searchPlaylists: ${playlists.length}');
    if (playlists.isNotEmpty) {
      final p = playlists.first;
      print('  [0] ${p.title} | creator=${p.creator} | count=${p.songCount} '
          '| id=${p.id} | cover=${p.coverUrl.isEmpty ? '(空)' : '有'}');
    }
  } catch (e) {
    print('searchPlaylists 异常: $e');
  }
  List<Artist> artists = const [];
  try {
    artists = await api.searchArtists(kw, size: 3);
    print('searchArtists: ${artists.length}');
    if (artists.isNotEmpty) {
      final a = artists.first;
      print('  [0] ${a.name} | id=${a.id} | songs=${a.songCount} '
          '| albums=${a.albumCount} | avatar=${a.avatarUrl.isEmpty ? '(空)' : '有'}');
    }
  } catch (e) {
    print('searchArtists 异常: $e');
  }
  if (artists.isNotEmpty) {
    try {
      final songs = await api.artistSongs(artists.first, size: 3);
      print('artistSongs(${artists.first.name}): ${songs.length}');
      if (songs.isNotEmpty) print('  [0] ${_songLine(songs.first)}');
    } catch (e) {
      print('artistSongs 异常: $e');
    }
  }
  List<Album> albums = const [];
  try {
    albums = await api.searchAlbums(kw, size: 3);
    print('searchAlbums: ${albums.length}');
    if (albums.isNotEmpty) {
      final a = albums.first;
      print('  [0] ${a.name} | id=${a.id} | artist=${a.artist} '
          '| count=${a.songCount} | pub=${a.publishTime} '
          '| cover=${a.coverUrl.isEmpty ? '(空)' : '有'}');
    }
  } catch (e) {
    print('searchAlbums 异常: $e');
  }
  if (albums.isNotEmpty) {
    try {
      final songs = await api.albumSongs(albums.first, size: 3);
      print('albumSongs(${albums.first.name}): ${songs.length}');
      if (songs.isNotEmpty) print('  [0] ${_songLine(songs.first)}');
    } catch (e) {
      print('albumSongs 异常: $e');
    }
  }
  try {
    final List<LyricHit> lyrics = await api.searchLyrics(kw, size: 3);
    print('searchLyrics: ${lyrics.length}');
    if (lyrics.isNotEmpty) {
      final h = lyrics.first;
      final snip = h.snippet.length > 50 ? '${h.snippet.substring(0, 50)}…' : h.snippet;
      print('  [0] ${_songLine(h.song)}');
      print('  snippet: $snip');
    }
  } catch (e) {
    print('searchLyrics 异常: $e');
  }
}
