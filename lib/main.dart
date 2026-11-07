import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'core/constants.dart';

bool get isWindows => !kIsWeb && Platform.isWindows;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
