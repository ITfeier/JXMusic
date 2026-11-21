import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../models/song.dart';
import 'local_music.dart';
import 'ohos_file_access.dart';

/// 单条系统导入音乐记录（持久化到 Hive `jx_settings` 的
/// [OhosSystemMusicService.storageKey]，应用重启后凭持久化授权继续可播）。
class OhosSystemTrack {
  const OhosSystemTrack({
    required this.uri,
    required this.title,
    required this.artist,
    this.album = '',
    this.cover = '',
    this.duration = 0,
  });

  /// 系统文件 URI（`file://docs/storage/...`），授权与打开都以它为键。
  final String uri;
  final String title;
  final String artist;
  final String album;

  /// 封面缓存文件路径（导入时从内嵌封面提取，空串表示无封面）。
  final String cover;
  final int duration;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'uri': uri,
    'title': title,
    'artist': artist,
    'album': album,
    'cover': cover,
    'duration': duration,
  };

  static OhosSystemTrack? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uri = raw['uri'];
    if (uri is! String || uri.isEmpty) return null;
    return OhosSystemTrack(
      uri: uri,
      title: (raw['title'] is String && (raw['title'] as String).isNotEmpty)
          ? raw['title'] as String
          : fileNameOf(uri),
      artist: raw['artist'] is String ? raw['artist'] as String : '未知歌手',
      album: raw['album'] is String ? raw['album'] as String : '',
      cover: raw['cover'] is String ? raw['cover'] as String : '',
      duration: raw['duration'] is int ? raw['duration'] as int : 0,
    );
  }

  Song toSong() => Song(
    id: 'ohossys_${uri.hashCode.toRadixString(16)}',
    platform: JXPlatform.local,
    title: title,
    artist: artist,
    album: album,
    coverUrl: cover,
    audioUrl: uri,
    duration: duration,
  );

  /// URI 末段文件名（URL 解码 + 去扩展名），标题回退用。
  static String fileNameOf(String uri) {
    try {
      final name = p.basenameWithoutExtension(Uri.decodeFull(uri));
      return name.isEmpty ? uri : name;
    } catch (_) {
      return uri;
    }
  }
}

/// 鸿蒙「系统音乐导入」服务：系统文件选择器导入 + 授权持久化 + 记录持久化。
///
/// 数据流：
/// - [importFromSystem]：选择器多选音频 URI → persistUris 持久化授权 →
///   逐个读取标签/封面（失败回退文件名）→ 追加写入 Hive；
/// - [loadSongs]：读记录 → activateUris 激活持久化授权 → 转成 [Song] 列表；
/// - [removeSong]：撤销授权 + 删除记录。
///
/// 播放不经过这里：系统歌曲的 `audioUrl` 即 URI，由 providers.dart 的
/// urlResolver 经 [OhosFileAccess.openFdUrl] 转成 `fd://` 交给 libmpv。
class OhosSystemMusicService {
  OhosSystemMusicService({
    OhosFileAccess? fileAccess,
    this.box,
    LocalMusicService? musicService,
    this.metadataParser,
  }) : _fileAccess = fileAccess ?? OhosFileAccess.instance,
       _musicService = musicService ?? LocalMusicService();

  /// Hive `jx_settings` 里存导入记录列表的键（List<Map>）。
  static const String storageKey = 'ohos_system_tracks';

  final OhosFileAccess _fileAccess;

  /// 可注入的 Hive Box（默认 `JXConstants.hiveBoxSettings` 的 jx_settings）。
  final Box<dynamic>? box;

  final LocalMusicService _musicService;

  /// 可注入的标签解析器（默认走 [OhosFileAccess.readMetadataByUri]）。
  final Future<AudioMetadata?> Function(String uri)? metadataParser;

  Box<dynamic> get _settingsBox =>
      box ?? Hive.box<dynamic>(JXConstants.hiveBoxSettings);

  /// 当前平台是否支持系统导入（仅鸿蒙；UI 据此显隐导入入口）。
  bool get isSupported => _fileAccess.isSupported;

  /// 已导入的记录数（不激活授权、不解析，快速计数用）。
  int get storedCount => _loadTracks().length;

  /// 读取已导入歌曲并激活持久化授权（应用重启后首次访问前必须激活）。
  ///
  /// 激活失败不阻断列表展示：个别 URI 授权失效时播放环节会给出「无法播放」。
  Future<List<Song>> loadSongs() async {
    final tracks = _loadTracks();
    if (tracks.isEmpty) return const <Song>[];
    try {
      await _fileAccess.activateUris(
        tracks.map((t) => t.uri).toList(growable: false),
      );
    } catch (e) {
      debugPrint('[JXMusic] 激活系统文件授权失败: $e');
    }
    return tracks.map((t) => t.toSong()).toList();
  }

  /// 从系统文件选择器导入：多选 → 持久化授权 → 逐个解析标签 → 落盘。
  ///
  /// 返回本次新增条数（用户取消/全部已存在返回 0）。
  /// [onProgress] 每解析完一个文件回调 `(done, total)`，供 UI 显示导入进度。
  Future<int> importFromSystem({
    void Function(int done, int total)? onProgress,
  }) async {
    final uris = await _fileAccess.pickAudioFiles();
    if (uris.isEmpty) return 0;

    final persisted = await _fileAccess.persistUris(uris);
    if (!persisted) {
      // 持久化失败（权限/能力缺失）不阻断本次导入：临时授权本次会话仍可播放，
      // 但重启后需重新导入——记录日志供排查。
      debugPrint('[JXMusic] 系统文件授权持久化失败，重启后需重新导入');
    }

    final existing = _loadTracks().map((t) => t.uri).toSet();
    final fresh = uris.where((u) => !existing.contains(u)).toList();
    if (fresh.isEmpty) return 0;

    final tracks = <OhosSystemTrack>[];
    for (var i = 0; i < fresh.length; i++) {
      tracks.add(await _buildTrack(fresh[i]));
      onProgress?.call(i + 1, fresh.length);
      // 逐文件解析之间让出事件循环，避免大批量导入卡 UI
      await Future<void>.delayed(Duration.zero);
    }
    await _saveTracks(<OhosSystemTrack>[..._loadTracks(), ...tracks]);
    return tracks.length;
  }

  /// 移除一首已导入歌曲：撤销授权 + 删除记录，返回剩余歌曲列表。
  Future<List<Song>> removeSong(Song song) async {
    final uri = song.audioUrl;
    final tracks = _loadTracks();
    final remain = <OhosSystemTrack>[];
    for (final t in tracks) {
      if (uri == null || t.uri != uri) remain.add(t);
    }
    if (remain.length != tracks.length) {
      await _saveTracks(remain);
      if (uri != null && uri.isNotEmpty) {
        try {
          await _fileAccess.revokeUris(<String>[uri]);
        } catch (_) {
          // 撤销失败（未持久化/已失效）不影响移除
        }
      }
    }
    return remain.map((t) => t.toSong()).toList();
  }

  /// 单个 URI -> 记录：读标签/封面，读不到回退文件名（与沙盒扫描同规则，
  /// 复用 [mergeFileNameFallback]）。
  Future<OhosSystemTrack> _buildTrack(String uri) async {
    var title = OhosSystemTrack.fileNameOf(uri);
    var artist = '未知歌手';
    var album = '';
    var cover = '';
    var duration = 0;
    var hasTagTitle = false;
    var hasTagArtist = false;
    try {
      final parser = metadataParser;
      final meta = parser != null
          ? await parser(uri)
          : await _fileAccess.readMetadataByUri(uri);
      if (meta != null) {
        final metaTitle = meta.title?.trim();
        if (metaTitle != null && metaTitle.isNotEmpty) {
          title = metaTitle;
          hasTagTitle = true;
        }
        final metaArtist = (meta.artist ?? meta.albumArtist)?.trim();
        if (metaArtist != null && metaArtist.isNotEmpty) {
          artist = metaArtist;
          hasTagArtist = true;
        }
        album = meta.album ?? '';
        duration = (meta.duration?.inSeconds) ?? 0;
        cover = await _musicService.extractCover(meta);
      }
    } catch (e) {
      debugPrint('[JXMusic] 解析系统音乐标签失败（回退文件名）: $e');
    }
    final merged = mergeFileNameFallback(
      baseName: OhosSystemTrack.fileNameOf(uri),
      title: title,
      artist: artist,
      hasTagTitle: hasTagTitle,
      hasTagArtist: hasTagArtist,
    );
    return OhosSystemTrack(
      uri: uri,
      title: merged.title,
      artist: merged.artist,
      album: album,
      cover: cover,
      duration: duration,
    );
  }

  List<OhosSystemTrack> _loadTracks() {
    Object? raw;
    try {
      raw = _settingsBox.get(storageKey);
    } catch (_) {
      return const <OhosSystemTrack>[];
    }
    if (raw is! List) return const <OhosSystemTrack>[];
    final out = <OhosSystemTrack>[];
    for (final item in raw) {
      final track = OhosSystemTrack.fromJson(item);
      if (track != null) out.add(track);
    }
    return out;
  }

  Future<void> _saveTracks(List<OhosSystemTrack> tracks) async {
    await _settingsBox.put(
      storageKey,
      tracks.map((t) => t.toJson()).toList(growable: false),
    );
  }
}
