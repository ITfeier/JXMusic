import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/player_service.dart';
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/settings_page.dart';

/// 主题自定义扩展（外观三选一 + 10 色扩展色板）：
/// - 外观模式：跟随系统 / 浅色 / 深色 三胶囊；
/// - 主题色：10 色板 Wrap 布局，点击即选即存（themeColorProvider + Hive）；
/// - Hive 写入用例必须放在最后一个 testWidgets（fake async 里 Hive 写队列
///   不再推进，之后 await 该 box 的操作会卡死；tearDownAll 不能
///   await Hive.close()，用 deleteSync try/catch 兜底）。
void main() {
  late Directory tempDir;
  late Box<dynamic> settingsBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('jx_theme_hive_');
    Hive.init(tempDir.path);
    settingsBox = await Hive.openBox<dynamic>(JXConstants.hiveBoxSettings);
    await Hive.openBox<Map>(JXConstants.hiveBoxAccounts);
  });

  tearDownAll(() async {
    // 不 await Hive.close()（见文件头注释），残留临时目录留给系统清理。
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<ProviderContainer> pumpSettings(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      musicHubProvider.overrideWithValue(MusicApiHub()),
      // SettingsPage 音效区 watch playerServiceProvider；测试不加载原生库
      playerServiceProvider.overrideWith(
          (ref) => PlayerService(initPlayer: false)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildJXTheme(JXColors.primary, darkMode: true),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('外观结构：三选项胶囊 + 10 色扩展色板齐全（无 Hive 写入）',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 1920); // 360dp 宽
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpSettings(tester);

    expect(find.text('外观模式'), findsOneWidget);
    expect(find.byKey(const ValueKey('themeModePill_system')), findsOneWidget);
    expect(find.byKey(const ValueKey('themeModePill_light')), findsOneWidget);
    expect(find.byKey(const ValueKey('themeModePill_dark')), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);

    // 10 个色块全部渲染（窄屏 Wrap 换行也不允许丢）
    for (final c in JXThemePalette.colors) {
      expect(
        find.byKey(ValueKey('themeSwatch${c.toARGB32()}')),
        findsOneWidget,
        reason: '色板应包含 ${c.toARGB32()}',
      );
    }
    expect(JXThemePalette.colors.length, 10,
        reason: '色板应为 10 色扩展配置');
  });

  testWidgets('外观交互：浅色/跟随系统/深色切换 + 主题色持久化（最后声明：写 Hive）',
      (tester) async {
    final container = await pumpSettings(tester);

    // 默认：深色（darkModeProvider 兜底 true），深色胶囊选中
    expect(container.read(darkModeProvider), isTrue);
    expect(container.read(followSystemThemeProvider), isFalse);

    // 1) 切浅色：深色开关关 + 跟随系统关，均落 Hive
    await tester.tap(find.text('浅色'));
    await tester.pump();
    expect(container.read(darkModeProvider), isFalse);
    expect(container.read(followSystemThemeProvider), isFalse);
    expect(settingsBox.get('darkMode'), isFalse,
        reason: 'darkMode 应持久化到 jx_settings');
    expect(settingsBox.get('followSystemTheme'), isFalse);

    // 2) 切跟随系统：只开 followSystem，darkMode 保持 false
    await tester.tap(find.text('跟随系统'));
    await tester.pump();
    expect(container.read(followSystemThemeProvider), isTrue);
    expect(container.read(darkModeProvider), isFalse);
    expect(settingsBox.get('followSystemTheme'), isTrue);

    // 3) 切回深色：跟随系统关 + 深色开
    await tester.tap(find.text('深色'));
    await tester.pump();
    expect(container.read(followSystemThemeProvider), isFalse);
    expect(container.read(darkModeProvider), isTrue);
    expect(settingsBox.get('darkMode'), isTrue);

    // 4) 点琥珀色块：themeColorProvider 切换并持久化（ARGB int）
    const amber = Color(0xFFF5A623);
    await tester.tap(find.byKey(ValueKey('themeSwatch${amber.toARGB32()}')));
    await tester.pump();
    expect(container.read(themeColorProvider), amber);
    expect(settingsBox.get('themeColor'), amber.toARGB32(),
        reason: '主题色应按 ARGB int 持久化');
  });
}
