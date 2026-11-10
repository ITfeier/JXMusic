import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'core/constants.dart';

bool get isWindows => !kIsWeb && Platform.isWindows;

/// 是否 Android（Web/Windows 上不成立）：系统栏相关调用只在这里生效。
bool get isAndroid => !kIsWeb && Platform.isAndroid;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android 15/16（targetSdk=36）已强制 edge-to-edge：状态栏/导航栏区域由 App
  // 自己绘制、由 lib/ui 的 MobilePageSafeArea 避让。这里显式声明一次，表达
  // 「App 主动选择 edge-to-edge」的意图（非 Android 平台完全跳过，Windows 桌面
  // 的自绘标题栏与窗口行为不受影响）。
  if (isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  // 播放引擎初始化（media_kit / libmpv）
  MediaKit.ensureInitialized();
  // 本地存储
  await Hive.initFlutter();
  await Hive.openBox<dynamic>(JXConstants.hiveBoxSettings);
  await Hive.openBox<Map>(JXConstants.hiveBoxHistory);
  await Hive.openBox<Map>(JXConstants.hiveBoxPlaylists);
  await Hive.openBox<Map>(JXConstants.hiveBoxAccounts);

  // Windows 窗口：隐藏默认标题栏，使用自绘液态玻璃标题栏
  if (isWindows) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(960, 640),
      center: true,
      title: JXConstants.appName,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden,
          windowButtonVisibility: true);
      // 恢复上次的窗口置顶偏好
      final alwaysOnTop = Hive.box<dynamic>(JXConstants.hiveBoxSettings)
              .get('alwaysOnTop', defaultValue: false) as bool? ??
          false;
      if (alwaysOnTop) {
        await windowManager.setAlwaysOnTop(true);
      }
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: JXApp()));
}
