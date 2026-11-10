import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/constants.dart';
import 'models/lyric.dart';
import 'models/song.dart';
import 'services/api/http.dart';
import 'services/api/music_api.dart';
import 'services/api/netease_api.dart';
import 'services/api/qq_api.dart';
import 'services/api/kugou_api.dart';
import 'services/library_store.dart';
import 'services/local_format_service.dart';
import 'services/local_formats/format_decoder.dart';
import 'services/local_formats/kgm_decoder.dart';
import 'services/local_formats/ncm_decoder.dart';
import 'services/local_formats/qmc_decoder.dart';
import 'services/local_music.dart';
import 'services/local_paths.dart';
import 'services/player_service.dart';

/// 平台登录态在 Hive 里的键（按平台区分）
String _accountKey(int platform) => 'platform_$platform';

/// 从 Hive 读回某个平台的登录态（存档损坏时按未登录处理）
AccountSession? _loadAccount(int platform) {
  try {
    final box = Hive.box<Map>(JXConstants.hiveBoxAccounts);
    final raw = box.get(_accountKey(platform));
    if (raw is Map) {
      return AccountSession.fromJson(Map<String, dynamic>.from(raw));
    }
  } catch (_) {}
  return null;
}

/// 平台 API 聚合入口。
/// 构造时会把本地保存的登录态灌回各平台客户端，保证重启后登录态仍生效。
final musicHubProvider = Provider<MusicApiHub>((ref) {
  final hub = MusicApiHub();
  for (final api in <MusicPlatformApi>[
    QQMusicApi(),
    NeteaseApi(),
    KuGouApi(),
  ]) {
    hub.register(api);
    api.restoreSession(_loadAccount(api.platform));
  }
  return hub;
});

/// 某个平台的登录态；登录/退出会同步写 Hive，重启后仍保持。
final accountProvider =
    StateNotifierProvider.family<AccountNotifier, AccountSession?, int>(
      (ref, platform) => AccountNotifier(platform, _loadAccount(platform)),
    );

class AccountNotifier extends StateNotifier<AccountSession?> {
  AccountNotifier(this.platform, AccountSession? initial) : super(initial);

  final int platform;

  /// 扫码登录成功后调用：更新内存状态并持久化
  void login(AccountSession session) {
    state = session;
    try {
      Hive.box<Map>(JXConstants.hiveBoxAccounts)
          .put(_accountKey(platform), session.toJson());
    } catch (_) {}
  }

  /// 退出登录：清内存状态、Hive 存档和平台客户端 cookie
  void logout() {
    state = null;
    try {
      Hive.box<Map>(JXConstants.hiveBoxAccounts).delete(_accountKey(platform));
    } catch (_) {}
  }
}

/// 本地曲库：播放历史 / 收藏 / 自建歌单（Hive 持久化）
final libraryProvider = ChangeNotifierProvider<LibraryStore>((ref) {
  // 不要在这里再写 `ref.onDispose(store.dispose)`：riverpod 2.x 的
  // ChangeNotifierProvider 在 provider 释放时会自动 dispose notifier，重复 dispose
  // 会在 debug 下触发 ChangeNotifier 的「used after being disposed」断言
  // （pump 音乐库页的 widget 测试 teardown 必现）。
  return LibraryStore();
});

/// 播放器服务（全局单例）。
/// 这里注入两个 resolver 与播放历史回调：
/// - 自动下一首/切歌时由 service 自行解析直链，避免队列里后续歌曲无法播放；
/// - 播放入口统一记录历史、自动加载歌词。
final playerServiceProvider = ChangeNotifierProvider<PlayerService>((ref) {
  final hub = ref.read(musicHubProvider);
  final library = ref.read(libraryProvider);

  Future<String?> resolveUrl(Song song) async {
    // 本地曲目：普通格式原样返回源路径；加密格式（NCM/QMC/KGM…）解密到缓存后
    // 返回缓存路径。失败时 LocalFormatService.lastError 记录中文原因（评审 R-11）。
    if (song.platform == JXPlatform.local) {
      try {
        return await ref.read(localFormatServiceProvider).playableUrl(song);
      } catch (_) {
        return null;
      }
    }
    final api = hub.api(song.platform);
    if (api == null) return song.audioUrl;
    try {
      return await api.getPlayUrl(song);
    } catch (_) {
      return null;
    }
  }

  Future<List<LyricLine>> resolveLyrics(Song song) async {
    final api = hub.api(song.platform);
    if (api == null) return const [];
    try {
      return LyricParser.parseLrc(await api.getLyrics(song));
    } catch (_) {
      return const [];
    }
  }

  final service = PlayerService(
    onSongStarted: library.addHistory,
    urlResolver: resolveUrl,
    lyricsResolver: resolveLyrics,
    onSettingChanged: saveSetting,
    // 队列懒解密失败时给 UI 一个具体中文原因（评审 R-11）
    resolutionErrorHint: () => ref.read(localFormatServiceProvider).lastError,
    initialVolume: _readSettingsDouble('volume', 80),
    initialLoopMode: _readSettingsInt('loopMode', 2),
    initialSpeed: _readSettingsDouble('speed', 1.0),
  );
  // 同上：ChangeNotifierProvider 会自动 dispose service，避免二次 dispose 断言。
  return service;
});

/// 本地音乐加密格式解密服务（NCM / QMC / KGM 解码器 + 解密缓存）。
final localFormatServiceProvider = Provider<LocalFormatService>((ref) {
  return LocalFormatService(
    decoders: <EncryptedAudioDecoder>[
      NcmDecoder(),
      QmcDecoder(),
      KgmDecoder(), // 默认用 rootBundle 读 assets/kugou_key.bin，实例内缓存/单飞
    ],
  );
});

/// 本地扫描目录配置（Hive 持久化，见 ADR-004 D5）。
final localPathsStoreProvider = Provider<LocalPathsStore>(
  (ref) => LocalPathsStore(),
);

/// 本地音乐扫描服务（多目录 + 加密格式识别）
final localMusicServiceProvider = Provider<LocalMusicService>((ref) {
  return LocalMusicService(
    formats: ref.read(localFormatServiceProvider),
    pathsStore: ref.read(localPathsStoreProvider),
  );
});

/// 深浅主题
final darkModeProvider = StateProvider<bool>((ref) {
  final box = Hive.box<dynamic>(JXConstants.hiveBoxSettings);
  return box.get('darkMode', defaultValue: true) as bool? ?? true;
});

/// 主题色
final themeColorProvider = StateProvider<Color>((ref) {
  final box = Hive.box<dynamic>(JXConstants.hiveBoxSettings);
  final v = box.get('themeColor');
  return v is int ? Color(v) : JXColors.primary;
});

/// 设置持久化助手
void saveSetting(String key, dynamic value) {
  final box = Hive.box<dynamic>(JXConstants.hiveBoxSettings);
  box.put(key, value is Color ? value.toARGB32() : value);
}

/// 从设置里读数值（带默认值）
double _readSettingsDouble(String key, double fallback) {
  try {
    final v = Hive.box<dynamic>(JXConstants.hiveBoxSettings).get(key);
    if (v is num) return v.toDouble();
  } catch (_) {}
  return fallback;
}

int _readSettingsInt(String key, int fallback) {
  try {
    final v = Hive.box<dynamic>(JXConstants.hiveBoxSettings).get(key);
    if (v is num) return v.toInt();
  } catch (_) {}
  return fallback;
}

/// 窗口置顶（Windows 桌面）
final alwaysOnTopProvider = StateProvider<bool>((ref) {
  try {
    final v = Hive.box<dynamic>(JXConstants.hiveBoxSettings).get('alwaysOnTop');
    if (v is bool) return v;
  } catch (_) {}
  return false;
});

/// 当前页面索引（导航）
final navIndexProvider = StateProvider<int>((ref) => 0);

/// 迷你播放窗口模式（桌面端）
final miniModeProvider = StateProvider<bool>((ref) => false);
