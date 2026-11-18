/// 专辑模型（搜索结果 / 专辑页入口）
class Album {
  final String id; // 平台内唯一 id
  final int platform; // JXPlatform.qq / netease / kugou
  final String name;
  final String coverUrl;
  final String artist;
  final int songCount;
  final String publishTime; // 发行时间（'2026-03-25' 或年份）

  const Album({
    required this.id,
    required this.platform,
    required this.name,
    this.coverUrl = '',
    this.artist = '',
    this.songCount = 0,
    this.publishTime = '',
  });

  /// 全局唯一键：platform:id
  String get globalId => '$platform:$id';
}
