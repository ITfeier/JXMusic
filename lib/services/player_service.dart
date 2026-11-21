import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../models/lyric.dart';
import 'audio_effect.dart';

/// 歌词加载状态（播放页三态渲染 + 重试用，PRD R1.3 契约：签名不得改）。
///
/// - [idle]：初始状态 / 停止播放 / 未注入歌词解析器；
/// - [loading]：切歌后正在异步请求歌词；
/// - [ready]：已拿到非空歌词；
/// - [empty]：请求成功但无歌词；
/// - [error]：请求抛错（网络异常等），UI 应展示重试按钮。
enum LyricsStatus { idle, loading, ready, empty, error }

/// 切换音源时替换当前队列项（纯函数，便于单测）。
///
/// 返回新队列与新索引：长度不变、[currentIndex] 位置被 [song] 替换，其它元素原样保留；
/// [currentIndex] 越界时返回原队列的等长副本、索引不变。**不修改入参队列**。
///
/// 注意：调用方必须先把结果算好、再整体替换内部队列（不要写成
/// `queue..clear()..addAll(replace(queue, ...))`——级联会先 clear，再对已清空的
/// 队列求值，导致队列被清空，见 test/source_switch_test.dart 的回归用例）。
({List<Song> queue, int index}) replaceCurrentInQueue({
  required List<Song> queue,
  required int currentIndex,
  required Song song,
}) {
  final next = List<Song>.of(queue);
  if (currentIndex < 0 || currentIndex >= next.length) {
    return (queue: next, index: currentIndex);
  }
  next[currentIndex] = song;
  return (queue: next, index: currentIndex);
}

/// 播放器服务：基于 media_kit (libmpv)，Windows/Android 双端
class PlayerService extends ChangeNotifier {
  /// [initPlayer] 仅测试用：false 时不创建 media_kit Player，
  /// 便于在不加载原生库的测试环境验证队列/切源逻辑；业务代码保持默认 true。
  PlayerService({
    this.onSongStarted,
    this.urlResolver,
    this.lyricsResolver,
    this.onSettingChanged,
    this.resolutionErrorHint,
    this.onlineResolutionErrorHint,
    double initialVolume = 80,
    int initialLoopMode = 2,
    double initialSpeed = 1.0,
    String initialAudioEffect = JXAudioEffects.noneId,
    bool initPlayer = true,
  })  : _playerCreationRequested = initPlayer {
    _volume = initialVolume;
    _loopMode = initialLoopMode;
    _speed = initialSpeed;
    _audioEffect = JXAudioEffects.isValid(initialAudioEffect)
        ? initialAudioEffect
        : JXAudioEffects.noneId;
    if (initPlayer) _init();
  }

  /// 是否请求过真实引擎创建：true 且 _player 为 null 说明引擎初始化失败
  /// （如 x86_64 模拟器缺 libmpv），点播时给出明确提示；
  /// 测试 initPlayer:false 则保持静默 no-op 语义。
  final bool _playerCreationRequested;

  /// 一首歌真正开始播放时回调（用于记录播放历史）
  final void Function(Song song)? onSongStarted;

  /// 播放直链解析器：队列里的歌曲可能还没解析过直链，切歌时按需解析
  final Future<String?> Function(Song song)? urlResolver;

  /// 歌词解析器：切歌时自动取歌词
  final Future<List<LyricLine>> Function(Song song)? lyricsResolver;

  /// 音量/循环模式/倍速变化时回调（用于持久化用户偏好）
  final void Function(String key, dynamic value)? onSettingChanged;

  /// 本地解密失败的具体中文原因提供者（由 LocalFormatService 提供，评审 R-11）；
  /// 为空时退回通用文案。
  final String? Function()? resolutionErrorHint;

  /// 在线曲目直链解析失败的具体中文原因提供者（平台 API 本次新增的
  /// lastError，播放失败诊断 P1 文案化）；为空时退回通用文案。
  final String? Function()? onlineResolutionErrorHint;

  String? _lastResolutionError;

  /// 最近一次切歌时本地曲目解析/解密失败的原因（中文，供 UI 提示）。
  String? get lastResolutionError => _lastResolutionError;

  /// UI 展示完提示后清除（不改变当前播放）。
  void clearResolutionError() {
    if (_lastResolutionError == null) return;
    _lastResolutionError = null;
    notifyListeners();
  }

  String? _lastSourceSwitchNotice;

  /// 最近一次跨平台兜底换歌的提示（中文，供全局 SnackBar 展示一次后清除；
  /// 播放失败诊断 P1：换平台不再静默）。
  String? get lastSourceSwitchNotice => _lastSourceSwitchNotice;

  /// 跨平台兜底成功换歌时上报提示（由 playback.resolveAndPlay 调用）。
  void reportSourceSwitch(String notice) {
    if (notice.trim().isEmpty) return;
    _lastSourceSwitchNotice = notice;
    notifyListeners();
  }

  /// UI 展示完提示后清除（不改变当前播放）。
  void clearSourceSwitchNotice() {
    if (_lastSourceSwitchNotice == null) return;
    _lastSourceSwitchNotice = null;
    notifyListeners();
  }

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

  /// 当前音效预设 id（audio_effect.dart 目录；默认原声）。
  String _audioEffect = JXAudioEffects.noneId;

  String get audioEffect => _audioEffect;
  // 歌词
  List<LyricLine> _lyrics = [];
  List<LyricLine> get lyrics => _lyrics;
  int _lyricIndex = -1;
  int get lyricIndex => _lyricIndex;

  LyricsStatus _lyricsStatus = LyricsStatus.idle;

  /// 当前歌词加载状态（初始 [LyricsStatus.idle]）。
  LyricsStatus get lyricsStatus => _lyricsStatus;

  /// 当前歌词请求所属曲目（globalId）：
  /// 用于「同一首歌重复 playSong 不重复请求」和丢弃过期响应。
  String? _lyricsSongId;

  /// 歌词请求序号：每次发起请求自增，异步返回时对比，过期响应直接丢弃。
  int _lyricsRequestId = 0;

  /// dispose 之后异步回调不得 notifyListeners（否则 debug 下断言失败）。
  bool _disposed = false;

  /// 播放代际号：每次发起新的播放流程自增；`_playAt` 里跨 await 的每一步
  /// 都要校验它没变，防止快速切歌/清空队列时旧的异步流程回来写脏数据
  /// （旧直链覆盖新队列项、旧曲目 open 迟到覆盖新曲目、RangeError）。
  int _playGeneration = 0;

  /// 已因播放器报错而自动重试过一次的歌曲（globalId）：
  /// 每首歌只自动重解析一次，防止直链持续失效时无限重试循环。
  String? _retriedSongId;

  /// 最近一次尝试播放的歌曲（globalId），用于判断「换歌」以重置重试标记。
  String? _lastPlayedSongId;

  /// 音量持久化防抖：拖动音量条每个 tick 都 setVolume，
  /// Hive 写入按 500ms 合并，避免 I/O 风暴。
  Timer? _volumePersistTimer;

  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _playSub;
  StreamSubscription? _completeSub;
  StreamSubscription? _playlistSub;
  StreamSubscription? _errSub;
  StreamSubscription? _logSub;

  Future<void> _init() async {
    try {
      // logLevel=warn（+43）：默认 error 拿不到 ffmpeg tcp/HTTP 细节日志，
      // 真机排障（libmpv 打开直链失败取证）需要 warn 级别进 hilog。
      _player = Player(
          configuration: PlayerConfiguration(logLevel: MPVLogLevel.warn));
    } catch (e) {
      // libmpv 缺失（如 x86_64 模拟器）：保持 _player 为 null，
      // 其余流程全部空安全跳过；点播时由 _playAt 给出明确提示。
      _player = null;
      debugPrint('[JXMusic] 播放器创建失败（播放功能不可用）: $e');
      return;
    }
    _player?.setVolume(_volume);
    if (_speed != 1.0) {
      _player?.setRate(_speed);
    }
    // 音效预设恢复（非原声才需要下发 mpv af）
    if (_audioEffect != JXAudioEffects.noneId) {
      await _applyAudioEffect();
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
    // mpv/media_kit 的 completed 流在 START_FILE（开始加载新文件）时也会发
    // completed=false，真正的「播完」只有 completed=true（eof-reached）。
    // 若不判值直接切歌，每次 open 新歌都会立刻被误切到下一首，级联中止
    // 所有进行中的加载并一路跳到队尾——真机「点了没反应/大量跳过」的
    // 根因（+43 修复：hilog 取证 START_FILE→切歌竞态）。
    _completeSub = _player?.stream.completed.listen(onCompletedEvent);
    // mpv 打开失败（如 CDN 直链过期）不会让 open() 抛异常，只走 error 流：
    // 监听错误事件，对在线曲目自动清掉过期直链并重新解析一次。
    _errSub = _player?.stream.error.listen((error) {
      _onPlayerError(error);
    });
    // mpv warn/error 细节日志（ffmpeg tcp/HTTP 等）转 debugPrint 进 hilog，
    // 供真机排障定位 libmpv 打开直链失败的具体网络层原因。
    _logSub = _player?.stream.log.listen((l) {
      if (l.level == 'error' || l.level == 'warn') {
        debugPrint('[JXMusic] mpv ${l.level}/${l.prefix}: ${l.text}');
      }
    });
  }

  /// 播放器报错：在线歌曲的直链可能已过期（历史/收藏里存的是解析时的 CDN
  /// 链接，几分钟到几小时就失效）。清掉队列项里的旧直链并重解析重开一次；
  /// 每首歌只重试一次，本地曲目不自动重试（解密失败重试结果相同）。
  /// 重试后仍失败（如设备端 libmpv 打不开直链）不再静默停止——真机反馈
  /// 「点了没反应」即此路径——提示后跳下一首（+43）。
  Future<void> _onPlayerError(String error) async {
    debugPrint('[JXMusic] 播放器错误: $error');
    if (_disposed) return;
    final song = currentSong;
    if (song == null) return;
    if (song.platform == JXPlatform.local) return;
    if (_retriedSongId == song.globalId) {
      // 重试一次后仍打开失败：给出明确提示，并按死链 autoAdvance 语义跳
      // 下一首（最后一首则提示后停下），不再无声卡死。
      if (_currentIndex + 1 < _queue.length) {
        _lastResolutionError = '「${song.title}」播放失败，已跳过';
        notifyListeners();
        await _playAt(_currentIndex + 1, autoAdvance: true);
      } else {
        _lastResolutionError = '「${song.title}」播放失败，可尝试切换其它平台音源';
        notifyListeners();
      }
      return;
    }
    _retriedSongId = song.globalId;
    final index = _currentIndex;
    if (index >= 0 && index < _queue.length &&
        _queue[index].globalId == song.globalId) {
      // copyWith 无法把字段置 null，经 toJson/fromJson 重建以清掉过期直链
      final cleared = Song.fromJson(song.toJson()
        ..['audioUrl'] = null);
      _queue[index] = cleared;
    }
    // 重试也按自动前进处理：重解析仍拿不到直链时跳下一首，不停死整个队列。
    await _playAt(index, autoAdvance: true);
    notifyListeners();
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

  /// media_kit completed 流统一入口（+43）：START_FILE 会发 completed=false
  /// （开始加载新文件），只有 eof-reached 的 completed=true 才代表播完。
  /// 不判值会在每次 open 新歌时立刻误切下一首（级联跳歌根因）。
  /// 公开仅供回归测试注入事件。
  @visibleForTesting
  void onCompletedEvent(bool completed) {
    if (!completed) return;
    unawaited(_onTrackComplete());
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
          await _playAt(next, autoAdvance: true);
        } else if (_loopMode == 2) {
          await _playAt(0, autoAdvance: true);
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

  /// 各曲目的多平台音源（key = song.globalId），用于播放页切换音源
  final Map<String, List<Song>> _sourcesBySong = {};

  /// 当前曲目可用的全部音源（单平台播放时为空列表）
  List<Song> get currentSources => currentSong == null
      ? const []
      : (_sourcesBySong[currentSong!.globalId] ?? const []);

  /// 当前曲目音源按平台顺序（QQ → 网易云 → 酷狗）
  List<Song> get orderedSources =>
      [...currentSources]..sort((a, b) => a.platform.compareTo(b.platform));

  /// 播放单曲：若在队列中则定位，否则替换队列。
  /// [sources] 传入该曲目在其它平台的音源，用于播放页「切换音源」。
  /// [replaceCurrent] 为 true 时用于切源：只替换当前队列项
  /// （[replaceCurrentInQueue]），队列长度与 [currentIndex] 保持不变；
  /// 当前位置越界时退回原有队列逻辑。
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    List<Song>? sources,
    bool replaceCurrent = false,
  }) async {
    if (sources != null && sources.isNotEmpty) {
      final gid = song.globalId;
      // LRU：重复播放时刷新插入顺序，超出 200 首淘汰最旧的音源记录，
      // 长会话里聚合搜索结果每首带全量音源，不设上限会无限增长。
      _sourcesBySong.remove(gid);
      _sourcesBySong[gid] = List<Song>.unmodifiable(sources);
      while (_sourcesBySong.length > 200) {
        _sourcesBySong.remove(_sourcesBySong.keys.first);
      }
    }
    if (replaceCurrent && _currentIndex >= 0 && _currentIndex < _queue.length) {
      // 先算好替换结果，再整体替换内部队列：级联 `..clear()..addAll(f(_queue))`
      // 会先 clear 再对已清空的 _queue 求值，历史 bug（队列被清空）。
      final replaced = replaceCurrentInQueue(
        queue: _queue,
        currentIndex: _currentIndex,
        song: song,
      );
      _queue
        ..clear()
        ..addAll(replaced.queue);
      _currentIndex = replaced.index;
    } else if (queue != null) {
      // 同样先对入参求值，再替换内部队列，避免对正在被清空的集合求值。
      final next = List<Song>.of(queue);
      final idx = next.indexWhere((s) => s.globalId == song.globalId);
      _queue
        ..clear()
        ..addAll(next);
      _currentIndex = idx >= 0 ? idx : 0;
    } else {
      final idx = _queue.indexWhere((s) => s.globalId == song.globalId);
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

  /// [autoAdvance] 为 true 表示本次播放来自自动前进（自然播完的下一首、
  /// 播放器报错后的重试）：曲目解析不出直链时提示后跳到队列下一首，
  /// 不让一首死链歌把整个队列卡死。用户主动点播保持原有「停下并提示」语义。
  Future<void> _playAt(int index, {bool autoAdvance = false}) async {
    if (index < 0 || index >= _queue.length) return;
    final generation = ++_playGeneration;
    _currentIndex = index;
    var song = _queue[index];
    // 换歌才重置「错误自动重试」标记：同一首歌的错误重试路径不能重置它，
    // 否则直链持续失效时会无限重试。
    if (_lastPlayedSongId != song.globalId) {
      _lastPlayedSongId = song.globalId;
      _retriedSongId = null;
    }

    // 歌词与音频解耦（PRD R1.3）：切歌即清空旧歌词 → loading → 立即异步请求。
    // 不依赖 _player.open 成功：无直链 / 本地解密失败时歌词仍应能展示。
    _loadLyricsFor(song);

    // 本地曲目（含 NCM/QMC/KGM 等加密格式）即使 audioUrl 非空也要走 resolver：
    // 普通格式原样返回源路径，加密格式返回解密缓存路径。
    // 解析结果只用于打开播放器，**不写回队列/播放历史**：历史/收藏必须保留
    // 源文件路径，否则解密缓存被清理后无法回放（评审 R-1）。
    String? playUrl = song.audioUrl;
    if (song.platform == JXPlatform.local) {
      try {
        final resolved = await urlResolver?.call(song);
        // 期间可能已切歌/清空队列：旧流程不得继续打开播放器
        if (generation != _playGeneration) return;
        // resolver 返回 null 表示解密/解析失败，绝不能回退到密文源路径。
        playUrl = (resolved == null || resolved.isEmpty) ? null : resolved;
      } catch (e) {
        debugPrint('[JXMusic] 本地音频解析失败: $e');
        playUrl = null;
      }
      if (playUrl == null || playUrl.isEmpty) {
        _lastResolutionError =
            resolutionErrorHint?.call() ?? '本地文件无法解密播放：${song.title}';
        debugPrint('[JXMusic] 本地曲目不可播: $_lastResolutionError');
        notifyListeners();
        return;
      }
      if (_lastResolutionError != null) _lastResolutionError = null;
    } else if (playUrl == null || playUrl.isEmpty) {
      // 队列里的歌曲可能只有平台 id、没有直链（例如"播放全部"、自动下一首），
      // 这里按需解析一次并回写队列，避免后续歌曲卡住播不了。
      try {
        playUrl = await urlResolver?.call(song);
      } catch (e) {
        debugPrint('[JXMusic] 直链解析失败: $e');
        playUrl = null;
      }
      if (generation != _playGeneration) return;
      if (playUrl != null && playUrl.isNotEmpty) {
        song = song.copyWith(audioUrl: playUrl);
        if (index < _queue.length &&
            _queue[index].globalId == song.globalId) {
          _queue[index] = song;
        }
      }
    }
    if (generation != _playGeneration) return;
    if (playUrl == null || playUrl.isEmpty) {
      debugPrint('[JXMusic] 歌曲无可播放链接: ${song.title}');
      // 播放失败诊断 P1（文案化）：有平台 API 的具体原因
      // （VIP/需登录/节目类/付费）就带进提示，不再只有笼统的「暂无播放链接」。
      final reason = onlineResolutionErrorHint?.call();
      final detail =
          (reason == null || reason.trim().isEmpty) ? '' : '（$reason）';
      if (autoAdvance && index + 1 < _queue.length) {
        // 自动前进遇到死链曲目（VIP/版权/试听限制解析不出直链）：
        // 提示一次后跳下一首，队列不中断。
        _lastResolutionError = '「${song.title}」暂无播放链接$detail，已跳过';
        notifyListeners();
        await _playAt(index + 1, autoAdvance: true);
        return;
      }
      _lastResolutionError =
          '「${song.title}」暂无播放链接$detail，可尝试切换其它平台音源';
      notifyListeners();
      return;
    }

    if (_player == null && _playerCreationRequested) {
      // 播放引擎不可用（初始化失败环境）：给出明确提示而不是静默无反应。
      _lastResolutionError = '播放引擎初始化失败，播放功能暂不可用';
      debugPrint('[JXMusic] 播放引擎不可用，无法播放: ${song.title}');
      notifyListeners();
      return;
    }
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
      await _player?.open(Media(playUrl, httpHeaders: headers), play: true);
      if (generation != _playGeneration) return;
      onSongStarted?.call(song);
    } catch (e) {
      debugPrint('[JXMusic] 播放失败: $e');
    }
    notifyListeners();
  }

  /// 切歌时加载歌词（PRD R1.3）：
  /// - 清空旧歌词 → 置 [LyricsStatus.loading] → 立即异步请求；
  /// - 同一首歌（globalId 相同）已加载/加载中时不重复请求（[force] 仅供重试）；
  /// - 响应返回时校验请求序号与当前曲目，过期响应丢弃；
  /// - 抛错 → [LyricsStatus.error]；成功但为空 → [LyricsStatus.empty]。
  void _loadLyricsFor(Song song, {bool force = false}) {
    final gid = song.globalId;
    final alreadyLoaded = _lyricsSongId == gid &&
        (_lyricsStatus == LyricsStatus.loading ||
            _lyricsStatus == LyricsStatus.ready ||
            _lyricsStatus == LyricsStatus.empty);
    if (!force && alreadyLoaded) return;

    _lyricsSongId = gid;
    _lyrics = const [];
    _lyricIndex = -1;
    final token = ++_lyricsRequestId;

    final resolver = lyricsResolver;
    if (resolver == null) {
      // 未注入解析器（例如纯队列测试）：不发起请求，保持 idle。
      _lyricsStatus = LyricsStatus.idle;
      notifyListeners();
      return;
    }

    _lyricsStatus = LyricsStatus.loading;
    notifyListeners();

    Future<List<LyricLine>> pending;
    try {
      pending = resolver(song);
    } catch (e) {
      _applyLyricsError(song, token, e);
      return;
    }
    pending.then((lines) {
      if (!_isCurrentLyricsResponse(song, token)) return;
      _lyrics = List<LyricLine>.unmodifiable(lines);
      _lyricIndex = -1;
      _lyricsStatus =
          _lyrics.isEmpty ? LyricsStatus.empty : LyricsStatus.ready;
      _updateLyricIndex();
      notifyListeners();
    }).catchError((Object e) {
      _applyLyricsError(song, token, e);
    });
  }

  /// 歌词请求异常：校验响应仍属于当前曲目/请求后，置 error 并通知一次。
  void _applyLyricsError(Song song, int token, Object error) {
    if (!_isCurrentLyricsResponse(song, token)) return;
    _lyrics = const [];
    _lyricIndex = -1;
    _lyricsStatus = LyricsStatus.error;
    debugPrint('[JXMusic] 歌词加载失败（${song.title}）: $error');
    notifyListeners();
  }

  /// 响应是否仍属于「当前曲目 + 当前请求」；dispose 后一律丢弃。
  bool _isCurrentLyricsResponse(Song song, int token) =>
      !_disposed &&
      token == _lyricsRequestId &&
      currentSong?.globalId == song.globalId;

  /// 重新请求当前曲目歌词（播放页「重试」按钮调用）。
  /// 无当前曲目 / 正在加载中 / 已 dispose 时安全 no-op。
  void retryLyrics() {
    if (_disposed) return;
    final song = currentSong;
    if (song == null) return;
    if (_lyricsStatus == LyricsStatus.loading) return;
    _loadLyricsFor(song, force: true);
  }

  Future<void> play() => _player?.play() ?? Future.value();
  Future<void> pause() => _player?.pause() ?? Future.value();

  Future<void> toggle() => _playing ? pause() : play();

  Future<void> seek(Duration d) => _player?.seek(d) ?? Future.value();

  Future<void> next() async {
    if (_queue.isEmpty) return;
    final next = _loopMode == 3 ? _randomIndex() : _currentIndex + 1;
    if (next >= _queue.length) {
      if (_loopMode == 2) {
        await _playAt(0, autoAdvance: true);
      }
      return;
    }
    // 按下一首的意图是让音乐继续：目标曲目是死链时提示后自动再往后跳。
    await _playAt(next, autoAdvance: true);
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    // 播放超过 3 秒则回到开头
    if (_position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    // 随机模式下上一首同样随机（与 next() 的行为保持一致）
    if (_loopMode == 3) {
      await _playAt(_randomIndex());
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
    // 拖动音量条每个 tick 都会调到这里：持久化按 500ms 防抖合并，
    // 避免一次拖动手势写几十次 Hive。
    _volumePersistTimer?.cancel();
    _volumePersistTimer = Timer(const Duration(milliseconds: 500), () {
      if (_disposed) return;
      onSettingChanged?.call('volume', _volume);
    });
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

  /// 切换音效预设（mpv `af` 滤镜链，见 audio_effect.dart）。
  /// 未知 id 忽略；重复设置同一预设直接跳过。
  Future<void> setAudioEffect(String id) async {
    if (!JXAudioEffects.isValid(id)) return;
    if (_audioEffect == id) return;
    _audioEffect = id;
    await _applyAudioEffect();
    onSettingChanged?.call('audioEffect', id);
    notifyListeners();
  }

  /// 把当前音效预设下发到 mpv（NativePlayer.setProperty "af"）。
  /// 原声 = 空滤镜链；播放器未创建（测试 initPlayer:false）或已释放时静默跳过。
  Future<void> _applyAudioEffect() async {
    final player = _player;
    if (player == null || _disposed) return;
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('af', JXAudioEffects.afFor(_audioEffect));
      }
    } catch (e) {
      debugPrint('[JXMusic] 音效下发失败: $e');
    }
  }

  /// 注入歌词（兼容既有调用与测试）：同步置 ready/empty。
  void setLyrics(List<LyricLine> lines) {
    _lyrics = lines;
    _lyricIndex = -1;
    _lyricsSongId = currentSong?.globalId;
    // 作废在途请求，避免异步返回覆盖手动注入的歌词
    _lyricsRequestId++;
    _lyricsStatus = lines.isEmpty ? LyricsStatus.empty : LyricsStatus.ready;
    _updateLyricIndex();
    notifyListeners();
  }

  /// 移除队列中某歌曲。
  ///
  /// 移除的是当前播放曲目时：若后面还有歌则接着播放顶上来的那首，
  /// 否则停止播放（不能让已移除的歌继续响、UI 却指向别的歌）。
  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    final wasCurrent = index == _currentIndex;
    _queue.removeAt(index);
    if (index < _currentIndex) {
      _currentIndex--;
    } else if (wasCurrent) {
      // 作废被移除曲目可能仍在途的解析/open 流程
      _playGeneration++;
      if (_currentIndex < _queue.length) {
        unawaited(_playAt(_currentIndex));
      } else {
        _stopPlayback();
      }
    }
    notifyListeners();
  }

  /// 停止播放并复位状态（清空队列/移除最后一首在播曲目时用）。
  void _stopPlayback() {
    unawaited(_player?.stop());
    _playing = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _currentIndex = -1;
    _lyrics = const [];
    _lyricIndex = -1;
    _lyricsSongId = null;
    _lyricsRequestId++;
    _lyricsStatus = LyricsStatus.idle;
  }

  void clearQueue() {
    _playGeneration++;
    _queue.clear();
    _stopPlayback();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _lyricsRequestId++; // 在途歌词响应不再 notify
    _volumePersistTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _completeSub?.cancel();
    _playlistSub?.cancel();
    _errSub?.cancel();
    _logSub?.cancel();
    _player?.dispose();
    super.dispose();
  }
}
