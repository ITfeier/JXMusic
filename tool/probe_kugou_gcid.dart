// 临时探针：用应用真实的 KuGouApi.playlistSongs 跑 gcid 分享链接全链路。
import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/playlist.dart';
import 'package:jxmusic/services/api/kugou_api.dart';

Future<void> main() async {
  final api = KuGouApi();
  final songs = await api.playlistSongs(const Playlist(
    id: '3zivrucnzoz01f',
    platform: JXPlatform.kugou,
    title: '',
  ));
  print('total=${songs.length}');
  for (final s in songs.take(3)) {
    print('${s.title} | ${s.artist} | vip=${s.vip} | dur=${s.duration}s');
  }
  print('last=${songs.isEmpty ? '-' : songs.last.title}');
}
