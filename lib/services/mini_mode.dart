import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// 迷你播放窗口：把主窗口缩成一个小播放条，并临时置顶。
/// 仅在桌面端可用。
class MiniMode {
  MiniMode._();

  static const Size _miniSize = Size(420, 150);
  static const Size _defaultMinSize = Size(960, 640);
  static const Size _defaultSize = Size(1280, 820);

  static Size? _savedSize;
  static bool _savedAlwaysOnTop = false;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  static Future<void> enter() async {
    if (!supported) return;
    try {
      _savedSize = await windowManager.getSize();
      _savedAlwaysOnTop = await windowManager.isAlwaysOnTop();
      await windowManager.setMinimumSize(const Size(360, 120));
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(_miniSize);
    } catch (e) {
      debugPrint('[JXMusic] 进入迷你模式失败: $e');
    }
  }

  static Future<void> exit() async {
    if (!supported) return;
    try {
      await windowManager.setMinimumSize(_defaultMinSize);
      await windowManager.setAlwaysOnTop(_savedAlwaysOnTop);
      await windowManager.setSize(_savedSize ?? _defaultSize);
    } catch (e) {
      debugPrint('[JXMusic] 退出迷你模式失败: $e');
    }
  }

  /// 拖动迷你窗口（自绘标题栏无系统拖拽区）
  static Future<void> startDrag() async {
    if (!supported) return;
    try {
      await windowManager.startDragging();
    } catch (_) {}
  }

  /// 收进托盘（隐藏窗口，不退出）
  static Future<void> hideToTray() async {
    if (!supported) return;
    try {
      await windowManager.hide();
    } catch (_) {}
  }
}
