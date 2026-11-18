import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/song.dart';
import 'player_service.dart';

/// ohos AVSession（系统媒体会话 + 后台长时任务）桥接层。
///
/// 原生侧（ohos/entry 的 JxAvSessionManager.ets）负责创建 AVSession、申请
/// AUDIO_PLAYBACK 长时任务；本类负责：
/// 1. 监听 [PlayerService]，把当前歌曲元数据（标题/歌手/封面/时长）与播放
///    状态（播放中/进度/倍速）推给原生，供锁屏与播控中心展示；
/// 2. 接收原生转发的系统媒体控制命令（play/pause/playNext/playPrevious/seek）
///    并转发回 [PlayerService]；
/// 3. 首次开始播放时申请后台长时任务，清空队列时释放。
///
/// 仅在 ohos 平台由 app.dart 初始化（[supported] 为准）；其它平台不实例化。
/// 通道异常一律静默降级：AVSession 不可用不影响播放本体。
class AvSessionService {
  AvSessionService(
      [this._channel = const MethodChannel('jxmusic/avsession')]);

  static final AvSessionService instance = AvSessionService();

  /// 仅 ohos 平台支持（原生侧才有 AVSession / 长时任务通道）。
  static bool get supported =>
      !kIsWeb && Platform.operatingSystem.toLowerCase() == 'ohos';

  final MethodChannel _channel;
  PlayerService? _player;
  bool _initialized = false;
  bool _backgroundStarted = false;

  /// 上次推送快照：避免每个进度 tick 都跨平台通道。
  String? _lastAssetId;
  bool? _lastPlaying;
  int _lastPositionPushMs = -1;

  /// 挂接播放器：注册命令回调 + 监听状态推送（幂等）。
  Future<void> init(PlayerService player) async {
    if (_initialized) return;
    _initialized = true;
    _player = player;
    _channel.setMethodCallHandler(_onNativeCommand);
    player.addListener(_onPlayerChanged);
    _onPlayerChanged();
  }

  /// 原生转发的系统媒体控制命令 → PlayerService。
  Future<dynamic> _onNativeCommand(MethodCall call) async {
    final player = _player;
    if (player == null) return null;
    switch (call.method) {
      case 'play':
        await player.play();
      case 'pause':
        await player.pause();
      case 'playNext':
        await player.next();
      case 'playPrevious':
        await player.previous();
      case 'seek':
        final args = call.arguments;
        final ms = args is Map ? _asInt(args['positionMs']) : null;
        if (ms != null) {
          await player.seek(Duration(milliseconds: ms));
        }
    }
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  /// PlayerService 状态变化 → 推送元数据 / 播放状态 / 后台任务。
  void _onPlayerChanged() {
    final player = _player;
    if (player == null) return;
    final song = player.currentSong;

    if (song == null) {
      // 队列已清空：释放后台长时任务，复位快照。
      if (_backgroundStarted) {
        _backgroundStarted = false;
        _invoke('stopBackground', null);
      }
      _lastAssetId = null;
      return;
    }

    final assetId = song.globalId;
    if (assetId != _lastAssetId) {
      _lastAssetId = assetId;
      _pushMetadata(player, song);
      _startBackgroundIfNeeded();
    }

    if (player.playing != _lastPlaying) {
      _lastPlaying = player.playing;
      _pushPlaybackState(player);
    } else if (player.playing) {
      // 播放中按进度增量节流（约 1s 一推）刷新锁屏进度条；暂停不推。
      final ms = player.position.inMilliseconds;
      if ((ms - _lastPositionPushMs).abs() >= 900) {
        _pushPlaybackState(player);
      }
    }
  }

  void _pushMetadata(PlayerService player, Song song) {
    _invoke('updateMetadata', <String, Object?>{
      'assetId': song.globalId,
      'title': song.title,
      'artist': song.artist,
      'durationMs': player.duration.inMilliseconds,
      'coverUrl': song.coverUrl,
    });
  }

  void _pushPlaybackState(PlayerService player) {
    _lastPositionPushMs = player.position.inMilliseconds;
    _invoke('updatePlaybackState', <String, Object?>{
      'playing': player.playing,
      'positionMs': player.position.inMilliseconds,
      'durationMs': player.duration.inMilliseconds,
      'speed': player.speed,
    });
  }

  void _startBackgroundIfNeeded() {
    if (_backgroundStarted) return;
    _backgroundStarted = true;
    _invoke('startBackground', null);
  }

  void _invoke(String method, Map<String, Object?>? args) {
    _channel.invokeMethod<void>(method, args).catchError((Object e) {
      // 原生侧未就绪（极早期切歌）或通道异常：静默，不打断播放。
      debugPrint('[JXMusic] AvSession $method 调用失败: $e');
    });
  }
}
