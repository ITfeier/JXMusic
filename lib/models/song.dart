/// 统一歌曲模型（聚合各平台）
class Song {
  final String id; // 平台内唯一 id
  final int platform; // JXPlatform.qq / netease / kugou / local
  final String title;
  final String artist;
  final String album;
  final String coverUrl; // 封面 URL 或本地封面路径
  final String? audioUrl; // 可播放 URL（可能需登录态/后续解析）
  final int duration; // 秒
  final bool vip; // 是否 VIP 歌曲
  final bool loginRequired; // 是否需要登录播放

  const Song({
    required this.id,
    required this.platform,
    required this.title,
    required this.artist,
    this.album = '',
    this.coverUrl = '',
    this.audioUrl,
    this.duration = 0,
    this.vip = false,
    this.loginRequired = false,
  });

  /// 全局唯一键：platform:id
  String get globalId => '$platform:$id';

  /// 复制并覆盖部分字段（播放/下载时用来注入解析出的 audioUrl 等）
  Song copyWith({
    String? id,
    int? platform,
    String? title,
    String? artist,
    String? album,
    String? coverUrl,
    String? audioUrl,
    int? duration,
    bool? vip,
    bool? loginRequired,
  }) =>
      Song(
        id: id ?? this.id,
        platform: platform ?? this.platform,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        coverUrl: coverUrl ?? this.coverUrl,
        audioUrl: audioUrl ?? this.audioUrl,
        duration: duration ?? this.duration,
        vip: vip ?? this.vip,
        loginRequired: loginRequired ?? this.loginRequired,
      );

  String get displayPlatform {
    switch (platform) {
      case 0:
        return 'QQ音乐';
      case 1:
        return '网易云';
      case 2:
        return '酷狗';
      case 3:
        return '本地';
      default:
        return '';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'platform': platform,
        'title': title,
        'artist': artist,
        'album': album,
        'coverUrl': coverUrl,
        'audioUrl': audioUrl,
        'duration': duration,
        'vip': vip,
        'loginRequired': loginRequired,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        id: json['id'] as String? ?? '',
        platform: json['platform'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        coverUrl: json['coverUrl'] as String? ?? '',
        audioUrl: json['audioUrl'] as String?,
        duration: json['duration'] as int? ?? 0,
        vip: json['vip'] as bool? ?? false,
        loginRequired: json['loginRequired'] as bool? ?? false,
      );
}
