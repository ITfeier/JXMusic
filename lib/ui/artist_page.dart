import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/artist.dart';
import '../models/song.dart';
import '../providers.dart';
import 'media_songs_page.dart';
import 'playlist_row.dart' show JXPlaylistCard;

/// 歌手页：搜索「歌手」结果进入，展示该歌手在所属平台的热门歌曲。
class ArtistPage extends ConsumerWidget {
  final Artist artist;

  const ArtistPage({super.key, required this.artist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MediaSongsPage(
      headerLabel: '歌手',
      title: artist.name,
      subtitle: JXPlaylistCard.platformShort(artist.platform),
      coverUrl: artist.avatarUrl,
      gradientIndex: artist.name.hashCode.abs(),
      roundCover: true,
      emptyText: '该歌手暂无歌曲',
      loader: (page, size) async {
        final api = ref.read(musicHubProvider).api(artist.platform);
        if (api == null) return const <Song>[];
        return api.artistSongs(artist, page: page, size: size);
      },
    );
  }
}
