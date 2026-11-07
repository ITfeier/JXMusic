import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'core/constants.dart';
import 'services/api/http.dart';
import 'services/api/music_api.dart';
import 'services/api/netease_api.dart';
import 'services/api/qq_api.dart';
import 'services/api/kugou_api.dart';
import 'services/local_music.dart';
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
  for (final api in <MusicPlatformApi>[QQMusicApi(), NeteaseApi(), KuGouApi()]) {
    hub.register(api);
    api.restoreSession(_loadAccount(api.platform));
  }
  return hub;
});

/// 某个平台的登录态；登录/退出会同步写 Hive，重启后仍保持。
final accountProvider =
    StateNotifierProvider.family<AccountNotifier, AccountSession?, int>(
        (ref, platform) => AccountNotifier(platform, _loadAccount(platform)));

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

/// 播放器服务（全局单例）
final playerServiceProvider = ChangeNotifierProvider<PlayerService>((ref) {
  final service = PlayerService();
  ref.onDispose(service.dispose);
  return service;
});

/// 本地音乐扫描服务
final localMusicServiceProvider =
    Provider<LocalMusicService>((ref) => LocalMusicService());

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

/// 当前页面索引（导航）
final navIndexProvider = StateProvider<int>((ref) => 0);
