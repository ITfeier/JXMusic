/// 歌手模型（搜索结果 / 歌手页入口）
class Artist {
  final String id; // 平台内唯一 id
  final int platform; // JXPlatform.qq / netease / kugou
  final String name;
  final String avatarUrl;
  final int albumCount;
  final int songCount;

  const Artist({
    required this.id,
    required this.platform,
    required this.name,
    this.avatarUrl = '',
    this.albumCount = 0,
    this.songCount = 0,
  });

  /// 全局唯一键：platform:id
  String get globalId => '$platform:$id';
}
