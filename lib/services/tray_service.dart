// 托盘使用 tray_manager 的 0.5.x 兼容 API（稳定、跨桌面平台一致）；
// 该 API 在 0.8.x 里被标记为 deprecated，这里显式忽略对应告警。
// ignore_for_file: deprecated_member_use, deprecated_member_use_from_same_package

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/window_manager.dart';

import 'player_service.dart';

/// 系统托盘 + 关闭到托盘：
/// - 左键托盘图标：显示/隐藏主窗口
/// - 右键菜单：显示窗口 / 播放暂停 / 上一首 / 下一首 / 退出
/// - 点击窗口关闭按钮：收进托盘而不是退出
class TrayService with TrayListener, WindowListener {
  TrayService._();

  static final TrayService instance = TrayService._();

  PlayerService? _player;
  bool _initialized = false;
  bool _trayReady = false;
  bool? _lastPlaying;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  Future<void> init(PlayerService player) async {
    if (!supported || _initialized) return;
    _initialized = true;
    _player = player;
    try {
      final iconPath = await _prepareIcon();
      if (iconPath != null) {
        await trayManager.setIcon(iconPath);
        await trayManager.setToolTip('JXMusic');
        _trayReady = true;
      }
      await _refreshMenu();
      trayManager.addListener(this);
      player.addListener(_onPlayerChanged);

      // 只有托盘图标创建成功才拦截关闭，避免托盘失败时窗口关不掉
      if (_trayReady) {
        windowManager.addListener(this);
        await windowManager.setPreventClose(true);
      }
    } catch (e) {
      debugPrint('[JXMusic] 托盘初始化失败: $e');
    }
  }

  /// 把打包进 assets 的托盘图标写到临时目录（tray_manager 需要真实文件路径）
  Future<String?> _prepareIcon() async {
    try {
      final data = await rootBundle.load('assets/tray_icon.ico');
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'jxmusic_tray.ico'));
      await file.writeAsBytes(data.buffer.asUint8List(), flush: false);
      return file.path;
    } catch (e) {
      debugPrint('[JXMusic] 托盘图标准备失败: $e');
      return null;
    }
  }

  Future<void> _refreshMenu() async {
    if (!_trayReady) return;
    final playing = _player?.playing ?? false;
    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '显示主窗口'),
        MenuItem.separator(),
        MenuItem(key: 'toggle', label: playing ? '暂停' : '播放'),
        MenuItem(key: 'prev', label: '上一首'),
        MenuItem(key: 'next', label: '下一首'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出 JXMusic'),
      ]));
    } catch (e) {
      debugPrint('[JXMusic] 刷新托盘菜单失败: $e');
    }
  }

  void _onPlayerChanged() {
    final playing = _player?.playing;
    if (playing != _lastPlaying) {
      _lastPlaying = playing;
      _refreshMenu();
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _hideWindow() async {
    await windowManager.hide();
  }

  /// 真正退出应用（托盘菜单 / 设置页都走这里）。
  ///
  /// 非桌面平台（如 ohos 手机）没有 window_manager 实现，走这里会抛
  /// MissingPluginException 导致「退出应用」按钮无效：直接 exit(0) 退出进程。
  Future<void> exitApp() async {
    try {
      trayManager.removeListener(this);
      await trayManager.destroy();
    } catch (_) {}
    if (!supported) {
      exit(0);
      return;
    }
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // ---- WindowListener：关闭按钮 -> 收进托盘 ----
  @override
  void onWindowClose() {
    if (!_trayReady) return;
    _hideWindow();
  }

  // ---- TrayListener ----
  @override
  void onTrayIconMouseDown() {
    () async {
      final visible = await windowManager.isVisible();
      if (visible) {
        await _hideWindow();
      } else {
        await _showWindow();
      }
    }();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _showWindow();
      case 'toggle':
        _player?.toggle();
      case 'prev':
        _player?.previous();
      case 'next':
        _player?.next();
      case 'exit':
        exitApp();
    }
  }
}
