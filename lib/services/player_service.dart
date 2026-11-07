import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import '../models/song.dart';
import '../models/lyric.dart';

/// 播放器服务：基于 media_kit (libmpv)，Windows/Android 双端
class PlayerService extends ChangeNotifier {
  PlayerService({
    this.onSongStarted,
    this.urlResolver,
    this.lyricsResolver,
    this.onSettingChanged,
    double initialVolume = 80,
    int initialLoopMode = 2,
    double initialSpeed = 1.0,
  }) {
    _volume = initialVolume;
    _loopMode = initialLoopMode;
    _speed = initialSpeed;
    _init();
  }

  /// 一首歌真正开始播放时回调（用于记录播放历史）
  final void Function(Song song)? onSongStarted;

  /// 播放直链解析器：队列里的歌曲可能还没解析过直链，切歌时按需解析
  final Future<String?> Function(Song song)? urlResolver;

  /// 歌词解析器：切歌时自动取歌词
  final Future<List<LyricLine>> Function(Song song)? lyricsResolver;

  /// 音量/循环模式/倍速变化时回调（用于持久化用户偏好）
  final void Function(String key, dynamic value)? onSettingChanged;

  Player? _player;

  // 播放状态
  bool _playing = false;
  bool get playing => _playing;

  Duration _position = Duration.zero;
  Duration get position => _position;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  // 队列
  final List<Song> _queue = [];
  List<Song> get queue => List.unmodifiable(_queue);

  int _currentIndex = -1;
  int get currentIndex => _currentIndex;
  Song? get currentSong => _currentIndex >= 0 && _currentIndex < _queue.length
      ? _queue[_currentIndex]
      : null;

  // 循环模式：0 顺序 / 1 单曲 / 2 列表循环 / 3 随机
  int _loopMode = 2;
  int get loopMode => _loopMode;

  // 音量 0-100
  double _volume = 80;
  double get volume => _volume;

  // 静音（记住静音前的音量）
  bool _muted = false;
  bool get muted => _muted;
  double _volumeBeforeMute = 80;

  // 播放速度
  double _speed = 1.0;
  double get speed => _speed;

  // 歌词
  List<LyricLine> _lyrics = [];
  List<LyricLine> get lyrics => _lyrics;
  int _lyricIndex = -1;
  int get lyricIndex => _lyricIndex;

  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _playSub;
  StreamSubscription? _completeSub;
  StreamSubscription? _playlistSub;

  Future<void> _init() async {
    _player = Player();
    _player?.setVolume(_volume);
    if (_speed != 1.0) {
      _player?.setRate(_speed);
    }

    _posSub = _player?.stream.position.listen((p) {
      _position = p;
      _updateLyricIndex();
      notifyListeners();
    });
    _durSub = _player?.stream.duration.listen((d) {
      _duration = d;
      notifyListeners();
    });
    _playSub = _player?.stream.playing.listen((p) {
      _playing = p;
      notifyListeners();
    });
    _completeSub = _player?.stream.completed.listen((_) {
      _onTrackComplete();
    });
  }

  void _updateLyricIndex() {
    if (_lyrics.isEmpty) {
      _lyricIndex = -1;
      return;
    }
    final ms = _position.inMilliseconds;
    var idx = -1;
    for (var i = 0; i < _lyrics.length; i++) {
      if (ms >= _lyrics[i].time) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx != _lyricIndex) {
      _lyricIndex = idx;
    }
  }

  Future<void> _onTrackComplete() async {
    if (_queue.isEmpty) return;
    switch (_loopMode) {
      case 1: // 单曲循环
        await seek(Duration.zero);
        await play();
        break;
      case 3: // 随机
        final next = _queue[_randomIndex()];
        await playSong(next);
        break;
      default:
        final next = _currentIndex + 1;
        if (next < _queue.length) {
          await _playAt(next);
        } else if (_loopMode == 2) {
          await _playAt(0);
        }
    }
  }

  int _randomIndex() {
    if (_queue.length <= 1) return 0;
    var r = _currentIndex;
    while (r == _currentIndex) {
      r = DateTime.now().millisecondsSinceEpoch % _queue.length;
    }
    return r;
  }

  /// 播放单曲：若在队列中则定位，否则替换队列
  Future<void> playSong(Song song, {List<Song>? queue}) async {
    if (queue != null) {
      _queue
        ..clear()
        ..addAll(queue);
      final idx = _queue.indexWhere(
          (s) => s.globalId == song.globalId);
      _currentIndex = idx >= 0 ? idx : 0;
    } else {
      final idx =
          _queue.indexWhere((s) => s.globalId == song.globalId);
      if (idx >= 0) {
        _currentIndex = idx;
      } else {
        _queue.add(song);
        _currentIndex = _queue.length - 1;
      }
    }
    await _playAt(_currentIndex);
  }

  /// 加入队列并播放（不替换现有队列）
  Future<void> addToQueueAndPlay(Song song) async {
    _queue.add(song);
    _currentIndex = _queue.length - 1;
    await _playAt(_currentIndex);
  }

  Future<void> _playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _currentIndex = index;
    var song = _queue[index];

    // 队列里的歌曲可能只有平台 id、没有直链（例如"播放全部"、自动下一首），
    // 这里按需解析一次并回写队列，避免后续歌曲卡住播不了。
    var url = song.audioUrl;
    if (url == null || url.isEmpty) {
      try {
        url = await urlResolver?.call(song);
      } catch (e) {
        debugPrint('[JXMusic] 直链解析失败: $e');
        url = null;
      }
      if (url != null && url.isNotEmpty) {
        song = song.copyWith(audioUrl: url);
        _queue[index] = song;
      }
    }
    if (url == null || url.isEmpty) {
      debugPrint('[JXMusic] 歌曲无可播放链接: ${song.title}');
      notifyListeners();
      return;
    }

    _lyrics = const [];
    _lyricIndex = -1;
    try {
      // 平台 CDN 播放需对应 Referer 头（QQ/酷狗/网易云各不相同）
      Map<String, String>? headers;
      if (song.platform == 0) {
        headers = {'Referer': 'https://y.qq.com/'};
      } else if (song.platform == 1) {
        headers = {'Referer': 'https://music.163.com/'};
      } else if (song.platform == 2) {
        headers = {'Referer': 'https://m.kugou.com/'};
      }
      await _player?.open(Media(url, httpHeaders: headers), play: true);
      onSongStarted?.call(song);
      _loadLyrics(song);
    } catch (e) {
      debugPrint('[JXMusic] 播放失败: $e');
    }
    notifyListeners();
  }

  /// 异步加载歌词；切歌后到达的旧响应会被丢弃
  void _loadLyrics(Song song) {
    final resolver = lyricsResolver;
    if (resolver == null) return;
    resolver(song).then((lines) {
      if (currentSong?.globalId != song.globalId) return;
      _lyrics = lines;
      _lyricIndex = -1;
      _updateLyricIndex();
      notifyListeners();
    }).catchError((Object e) {
      debugPrint('[JXMusic] 歌词加载失败: $e');
    });
  }

  Future<void> play() => _player?.play() ?? Future.value();
  Future<void> pause() => _player?.pause() ?? Future.value();

  Future<void> toggle() =>
      _playing ? pause() : play();

  Future<void> seek(Duration d) => _player?.seek(d) ?? Future.value();

  Future<void> next() async {
    if (_queue.isEmpty) return;
    final next = _loopMode == 3 ? _randomIndex() : _currentIndex + 1;
    if (next >= _queue.length) {
      if (_loopMode == 2) {
        await _playAt(0);
      }
      return;
    }
    await _playAt(next);
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    // 播放超过 3 秒则回到开头
    if (_position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    final prev = _currentIndex - 1;
    if (prev >= 0) {
      await _playAt(prev);
    } else if (_loopMode == 2) {
      await _playAt(_queue.length - 1);
    }
  }

  void setLoopMode(int mode) {
    _loopMode = mode;
    onSettingChanged?.call('loopMode', mode);
    notifyListeners();
  }

  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    if (_volume > 0) {
      _muted = false;
      _volumeBeforeMute = _volume;
    }
    await _player?.setVolume(_muted ? 0 : _volume);
    onSettingChanged?.call('volume', _volume);
    notifyListeners();
  }

  /// 静音 / 取消静音（记住静音前的音量）
  Future<void> toggleMute() async {
    if (_muted) {
      _muted = false;
      _volume = _volumeBeforeMute > 0 ? _volumeBeforeMute : 80;
    } else {
      _volumeBeforeMute = _volume;
      _muted = true;
    }
    await _player?.setVolume(_muted ? 0 : _volume);
    notifyListeners();
  }

  /// 设置播放速度（0.25x ~ 2.0x）
  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.25, 2.0);
    await _player?.setRate(_speed);
    onSettingChanged?.call('speed', _speed);
    notifyListeners();
  }

  /// 注入歌词
  void setLyrics(List<LyricLine> lines) {
    _lyrics = lines;
    _lyricIndex = -1;
    _updateLyricIndex();
    notifyListeners();
  }

  /// 移除队列中某歌曲
  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    if (index < _currentIndex) _currentIndex--;
    notifyListeners();
  }

  void clearQueue() {
    _queue.clear();
    _currentIndex = -1;
    _lyrics = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _completeSub?.cancel();
    _playlistSub?.cancel();
    _player?.dispose();
    super.dispose();
  }
}
