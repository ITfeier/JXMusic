// 手机端顶部安全区适配 · QA 独立验收用例（清 / P6）
//
// 依据：docs/projects/手机端顶部安全区适配/立项单.md 的 G1~G4。
// 原则：**只按行为断言，不看实现方的修复手段**——SafeArea / Padding /
// MediaQuery 计算 / 壳层包一层，只要「首个可交互内容（文字、输入框）」的
// 全局坐标确实避开了系统安全区，就算通过；实现细节变了本文件不需要改。
//
// 覆盖：
// - G1/G2 竖屏矩阵：MediaQuery.padding.top ∈ {0,24,36,48}dp × 宽度
//   ∈ {320,360,393,412}dp（320×568 / 360×640 / 393×852 / 412×915，
//   另补 360×800）；五个 tab（首页/搜索/音乐库/本地/设置）各自首个可交互
//   内容 top >= padding.top，且切换 tab 时不得出现 RenderFlex overflow。
// - G2 横屏：640×360dp、padding.left/right=44dp 时顶部内容不落进刘海区；
//   915×412dp（宽 >=840 会走桌面布局）同样要求不落进系统栏/刘海区。
// - G4 桌面回归：1280×820dp 仍走桌面布局（侧栏 + 顶部工具条、无手机底栏），
//   且桌面布局不受「手机安全区注入的 padding」影响（几何不变）。
//
// 说明：
// - 评测环境注入的 padding 是「物理像素」，FakeViewPadding 按 dp × dpr 换算；
// - 本文件不联网：三平台 API 用空 MusicApiHub，播放器用 initPlayer:false，
//   本地扫描目录注入为空列表，Hive 用临时目录；
// - 状态栏图标可见性（G3）无法在 widget 测试里判定，由模拟器截图验收。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/local_format_service.dart';
import 'package:jxmusic/services/local_formats/format_decoder.dart';
import 'package:jxmusic/services/local_music.dart';
import 'package:jxmusic/services/local_paths.dart';
import 'package:jxmusic/services/player_service.dart';
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/home_page.dart';
import 'package:jxmusic/ui/library_page.dart';
import 'package:jxmusic/ui/local_page.dart';
import 'package:jxmusic/ui/search_page.dart';
import 'package:jxmusic/ui/settings_page.dart';
import 'package:jxmusic/ui/shell_page.dart';

/// 五个 tab 按 navIndexProvider 的顺序排列（与 ShellPage 一致）。
const List<Type> _tabs = <Type>[
  HomePage,
  SearchPage,
  LibraryPage,
  LocalPage,
  SettingsPage,
];

const List<String> _tabNames = <String>['首页', '搜索', '音乐库', '本地', '设置'];

/// 竖屏矩阵：立项单 G2「竖屏 320×568、360×640、360×800、393×852、412×915」。
const List<(Size, String)> _portraitSizes = <(Size, String)>[
  (Size(320, 568), '320x568'),
  (Size(360, 640), '360x640'),
  (Size(360, 800), '360x800'),
  (Size(393, 852), '393x852'),
  (Size(412, 915), '412x915'),
];

/// 安全区取值：0（对照）/24（普通状态栏）/36（挖孔）/48（大屏刘海或平板）。
const List<double> _topPaddings = <double>[0, 24, 36, 48];

late Directory _hiveDir;

/// 取 Finder 命中的全部渲染盒在**全局坐标**下的矩形（跳过未布局/未挂载的）。
List<Rect> _globalRects(Finder finder) {
  final rects = <Rect>[];
  for (final element in finder.evaluate()) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox) continue;
    if (!renderObject.attached || !renderObject.hasSize) continue;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    rects.add(topLeft & renderObject.size);
  }
  return rects;
}

/// 某个 tab 页内的「可交互内容」矩形：文字 + 输入框。
///
/// 标题、搜索框提示语、按钮文字都是 Text / EditableText，足够覆盖 G1 的
/// 「文字/按钮/输入框」；不把装饰性背景 Container 算进来，避免误判。
List<Rect> _contentRects(WidgetTester tester, Type page) {
  final pageFinder = find.byType(page);
  expect(pageFinder, findsWidgets, reason: '$page 未出现在 ShellPage 中');
  return <Rect>[
    ..._globalRects(
      find.descendant(of: pageFinder, matching: find.byType(Text)),
    ),
    ..._globalRects(
      find.descendant(of: pageFinder, matching: find.byType(EditableText)),
    ),
  ];
}

double _minTop(List<Rect> rects) =>
    rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);

double _minLeft(List<Rect> rects) =>
    rects.map((r) => r.left).reduce((a, b) => a < b ? a : b);

/// 挂载真实手机壳层（ShellPage），注入可控的 MediaQuery 安全区。
///
/// 返回 ProviderContainer，便于测试里直接切 tab（等价于点底部导航）。
Future<ProviderContainer> _pumpShell(
  WidgetTester tester, {
  required double widthDp,
  required double heightDp,
  double topDp = 0,
  double bottomDp = 0,
  double leftDp = 0,
  double rightDp = 0,
  double devicePixelRatio = 3.0,
  bool dark = false,
}) async {
  tester.view.physicalSize = Size(
    widthDp * devicePixelRatio,
    heightDp * devicePixelRatio,
  );
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.padding = FakeViewPadding(
    top: topDp * devicePixelRatio,
    bottom: bottomDp * devicePixelRatio,
    left: leftDp * devicePixelRatio,
    right: rightDp * devicePixelRatio,
  );
  addTearDown(tester.view.reset);

  final settingsBox = Hive.box<dynamic>(JXConstants.hiveBoxSettings);
  // 注入空扫描目录：不 seed 默认目录、不扫真实文件系统，保证测试可重复。
  final pathsStore = LocalPathsStore(
    box: settingsBox,
    defaultCandidatesProvider: () async => const <String>[],
  );
  final formatService =
      LocalFormatService(decoders: const <EncryptedAudioDecoder>[]);

  final container = ProviderContainer(
    overrides: <Override>[
      // 不联网：空 hub，各平台 api 为 null，页面走空数据分支。
      musicHubProvider.overrideWithValue(MusicApiHub()),
      // 不加载 libmpv：播放条/序列化都用空播放器。
      playerServiceProvider.overrideWith(
        (ref) => PlayerService(initPlayer: false),
      ),
      localFormatServiceProvider.overrideWithValue(formatService),
      localPathsStoreProvider.overrideWithValue(pathsStore),
      localMusicServiceProvider.overrideWithValue(
        LocalMusicService(formats: formatService, pathsStore: pathsStore),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildJXTheme(JXColors.primary, darkMode: dark),
        home: const Scaffold(body: ShellPage()),
      ),
    ),
  );
  // 页面里有异步初始化（本地目录 load / 首页拉取），有界 pump，不用
  // pumpAndSettle：loading 动画可能一直转，settle 会等到超时。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
  return container;
}

Future<void> _switchTab(
  WidgetTester tester,
  ProviderContainer container,
  int index,
) async {
  container.read(navIndexProvider.notifier).state = index;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  setUpAll(() async {
    _hiveDir = await Directory.systemTemp.createTemp('jx_safe_area_accept_');
    Hive.init(_hiveDir.path);
    await Hive.openBox<dynamic>(JXConstants.hiveBoxSettings);
    await Hive.openBox<Map>(JXConstants.hiveBoxHistory);
    await Hive.openBox<Map>(JXConstants.hiveBoxPlaylists);
    await Hive.openBox<Map>(JXConstants.hiveBoxAccounts);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await _hiveDir.delete(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响结论
    }
  });

  // ================= G1 / G2 竖屏矩阵 =================
  for (final (size, label) in _portraitSizes) {
    for (final topPadding in _topPaddings) {
      final tag = '$label padding.top=${topPadding.toInt()}dp';
      testWidgets('G1/G2 竖屏 $tag：五页首个可交互内容不落进状态栏、无溢出',
          (tester) async {
        final container = await _pumpShell(
          tester,
          widthDp: size.width,
          heightDp: size.height,
          topDp: topPadding,
        );

        for (var i = 0; i < _tabs.length; i++) {
          await _switchTab(tester, container, i);
          final tabName = _tabNames[i];

          // G1 附带要求：任何页面不得出现 RenderFlex overflow 等布局异常。
          expect(
            tester.takeException(),
            isNull,
            reason: '$tag / $tabName 页出现布局异常（如 RenderFlex overflow）',
          );

          final rects = _contentRects(tester, _tabs[i]);
          expect(rects, isNotEmpty, reason: '$tag / $tabName 页没有可测量的内容');

          final minTop = _minTop(rects);
          expect(
            minTop,
            greaterThanOrEqualTo(topPadding - 0.5),
            reason: '$tag / $tabName：首个内容 top=${minTop.toStringAsFixed(2)}dp '
                '低于状态栏安全区 padding.top=${topPadding.toInt()}dp（会被状态栏/刘海压住）',
          );

          // 顶部内容还必须真的在首屏内（防止「留白过大把标题顶出屏幕」）。
          expect(
            minTop,
            lessThan(size.height),
            reason: '$tag / $tabName：首个内容 top=${minTop.toStringAsFixed(2)}dp '
                '超出屏幕高度 ${size.height.toInt()}dp',
          );
        }
      });
    }
  }

  // ================= G2 横屏 640×360 =================
  testWidgets('G2 横屏 640x360dp（左右安全区 44dp）：五页顶部内容不落进刘海区',
      (tester) async {
    const width = 640.0;
    const height = 360.0;
    const sidePadding = 44.0;

    final container = await _pumpShell(
      tester,
      widthDp: width,
      heightDp: height,
      leftDp: sidePadding,
      rightDp: sidePadding,
    );

    for (var i = 0; i < _tabs.length; i++) {
      await _switchTab(tester, container, i);
      final tabName = _tabNames[i];
      expect(tester.takeException(), isNull,
          reason: '横屏 640x360 / $tabName 出现布局异常（如 RenderFlex overflow）');

      final rects = _contentRects(tester, _tabs[i]);
      expect(rects, isNotEmpty, reason: '横屏 640x360 / $tabName 没有可测量内容');

      final minLeft = _minLeft(rects);
      expect(
        minLeft,
        greaterThanOrEqualTo(sidePadding - 0.5),
        reason: '横屏 640x360 / $tabName：内容最左 '
            'left=${minLeft.toStringAsFixed(2)}dp < 左侧安全区 ${sidePadding.toInt()}dp',
      );
    }

    // 搜索框最靠右的输入区域必须整体在右侧安全区内（覆盖「右刘海」场景）。
    // 注意：IndexedStack 未选中的页面是 offstage，默认 Finder 会跳过，
    // 所以先切回搜索页再测量。
    await _switchTab(tester, container, 1);
    final searchField = find.descendant(
      of: find.byType(SearchPage),
      matching: find.byType(TextField),
    );
    expect(searchField, findsOneWidget, reason: '搜索页应有搜索输入框');
    final fieldRect = tester.getRect(searchField);
    expect(fieldRect.left, greaterThanOrEqualTo(sidePadding - 0.5),
        reason: '搜索框左边界 ${fieldRect.left.toStringAsFixed(2)}dp 落进左侧安全区');
    expect(fieldRect.right, lessThanOrEqualTo(width - sidePadding + 0.5),
        reason: '搜索框右边界 ${fieldRect.right.toStringAsFixed(2)}dp 落进右侧安全区');
  });

  // ================= G2 横屏 640×360 无刘海对照 =================
  testWidgets('G2 横屏 640x360dp（无刘海对照）：五页不出现布局溢出',
      (tester) async {
    final container = await _pumpShell(
      tester,
      widthDp: 640,
      heightDp: 360,
      devicePixelRatio: 2.0,
    );

    for (var i = 0; i < _tabs.length; i++) {
      await _switchTab(tester, container, i);
      expect(tester.takeException(), isNull,
          reason: '横屏 640x360（无刘海）/ ${_tabNames[i]} 出现布局异常（如 RenderFlex overflow）');
    }
  });

  // ================= G2 横屏 915×412（宽 >=840，走桌面布局） =================
  testWidgets('G2 横屏 915x412dp：顶部内容不落进系统栏（宽 >=840 时同样要求）',
      (tester) async {
    const size = Size(915, 412);
    const topPadding = 24.0;

    final container = await _pumpShell(
      tester,
      widthDp: size.width,
      heightDp: size.height,
      topDp: topPadding,
      devicePixelRatio: 2.0,
    );

    for (var i = 0; i < _tabs.length; i++) {
      await _switchTab(tester, container, i);
      final tabName = _tabNames[i];
      expect(tester.takeException(), isNull,
          reason: '横屏 915x412 / $tabName 出现布局异常（如 RenderFlex overflow）');

      final rects = _contentRects(tester, _tabs[i]);
      expect(rects, isNotEmpty, reason: '横屏 915x412 / $tabName 没有可测量内容');
      final minTop = _minTop(rects);
      expect(
        minTop,
        greaterThanOrEqualTo(topPadding - 0.5),
        reason: '横屏 915x412 / $tabName：内容 top=${minTop.toStringAsFixed(2)}dp '
            '低于状态栏安全区 ${topPadding.toInt()}dp',
      );
    }
  });

  // ================= G4 桌面回归 1280×820 =================
  testWidgets('G4 桌面 1280x820dp：仍为桌面布局（侧栏+顶部工具条、无手机底栏）',
      (tester) async {
    await _pumpShell(
      tester,
      widthDp: 1280,
      heightDp: 820,
      devicePixelRatio: 1.0,
    );

    // 桌面顶栏面包屑是桌面布局独有元素（手机版壳层没有）。
    expect(find.text('/ 推荐'), findsOneWidget,
        reason: '1280x820 应走桌面布局（顶部工具条含面包屑）');

    // 手机版底部 Tab 不存在：导航图标只应出现在左侧侧栏（x < 120dp），
    // 且不应有任何导航图标落到靠近底部的手机 Tab 区域（y > height-120dp）。
    const navIcons = <IconData>[
      Icons.home_rounded,
      Icons.library_music_rounded,
      Icons.settings_rounded,
    ];
    for (final icon in navIcons) {
      final rects = _globalRects(find.byIcon(icon));
      expect(rects, isNotEmpty, reason: '桌面侧栏应包含导航图标 $icon');
      for (final rect in rects) {
        expect(rect.center.dy, lessThan(820 - 120),
            reason: '导航图标 $icon 出现在 y=${rect.center.dy.toStringAsFixed(1)}dp，'
                '疑似出现手机版底部 Tab（桌面端不应有）');
      }
    }
    // 侧栏确实在左侧（首页图标贴左）。
    final homeIconRects = _globalRects(find.byIcon(Icons.home_rounded));
    expect(homeIconRects.where((r) => r.center.dx < 120), isNotEmpty,
        reason: '桌面布局应在左侧侧栏显示导航图标');

    // 顶部工具条标题位于侧栏右侧、贴近顶部。
    final titleRects = _globalRects(find.text('首页'));
    expect(titleRects.length, greaterThanOrEqualTo(2),
        reason: '桌面布局应有侧栏「首页」与顶部标题「首页」');
    final topBarTitle = titleRects.reduce((a, b) => a.left > b.left ? a : b);
    expect(topBarTitle.left, greaterThan(120),
        reason: '顶部标题应位于侧栏右侧，实际 left=${topBarTitle.left.toStringAsFixed(1)}dp');
    expect(topBarTitle.top, lessThan(60),
        reason: '顶部标题应贴近窗口顶部，实际 top=${topBarTitle.top.toStringAsFixed(1)}dp');
    expect(tester.takeException(), isNull,
        reason: '1280x820 桌面布局不应出现布局异常');
  });

  testWidgets('G4 桌面安全区隔离：注入手机 padding 不改变桌面顶部几何',
      (tester) async {
    // Windows 真实情况：无系统状态栏，padding=0；先量桌面顶部标题位置。
    await _pumpShell(
      tester,
      widthDp: 1280,
      heightDp: 820,
      devicePixelRatio: 1.0,
    );
    final baseline = _globalRects(find.text('首页'))
        .reduce((a, b) => a.left > b.left ? a : b);

    // 同一棵树里注入手机式 padding：桌面布局必须保持不动（安全区只作用于手机）。
    tester.view.padding = const FakeViewPadding(top: 24, left: 44, right: 44);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final shifted = _globalRects(find.text('首页'))
        .reduce((a, b) => a.left > b.left ? a : b);

    expect(shifted.left, closeTo(baseline.left, 0.01),
        reason: '桌面布局被手机安全区左移：${baseline.left} -> ${shifted.left}');
    expect(shifted.top, closeTo(baseline.top, 0.01),
        reason: '桌面布局被手机安全区下移：${baseline.top} -> ${shifted.top}');
  });
}
