/// 播放列表 / 歌单模型
class Playlist {
  final String id;
  final int platform;
  final String title;
  final String coverUrl;
  final String creator;
  final int songCount;
  final String? detailUrl; // 歌单详情 API

  const Playlist({
    required this.id,
    required this.platform,
    required this.title,
    this.coverUrl = '',
    this.creator = '',
    this.songCount = 0,
    this.detailUrl,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'platform': platform,
        'title': title,
        'coverUrl': coverUrl,
        'creator': creator,
        'songCount': songCount,
        'detailUrl': detailUrl,
      };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
        id: json['id'] as String? ?? '',
        platform: json['platform'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        coverUrl: json['coverUrl'] as String? ?? '',
        creator: json['creator'] as String? ?? '',
        songCount: json['songCount'] as int? ?? 0,
        detailUrl: json['detailUrl'] as String?,
      );
}
