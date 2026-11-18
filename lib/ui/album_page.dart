import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album.dart';
import '../models/song.dart';
import '../providers.dart';
import 'media_songs_page.dart';

/// 专辑页：搜索「专辑」结果进入，展示专辑内歌曲。
class AlbumPage extends ConsumerWidget {
  final Album album;

  const AlbumPage({super.key, required this.album});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = <String>[
      if (album.artist.trim().isNotEmpty) album.artist.trim(),
      if (album.publishTime.trim().isNotEmpty) album.publishTime.trim(),
    ];
    return MediaSongsPage(
      headerLabel: '专辑',
      title: album.name,
      subtitle: parts.join(' · '),
      coverUrl: album.coverUrl,
      gradientIndex: album.name.hashCode.abs(),
      emptyText: '该专辑暂无歌曲',
      loader: (page, size) async {
        final api = ref.read(musicHubProvider).api(album.platform);
        if (api == null) return const <Song>[];
        return api.albumSongs(album, page: page, size: size);
      },
    );
  }
}
