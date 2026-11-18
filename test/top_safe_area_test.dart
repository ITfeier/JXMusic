import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/local_format_service.dart';
import 'package:jxmusic/services/local_formats/format_decoder.dart';
import 'package:jxmusic/services/local_music.dart';
import 'package:jxmusic/services/local_paths.dart';
import 'package:jxmusic/services/player_service.dart';
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/home_page.dart';
import 'package:jxmusic/ui/layout.dart';
import 'package:jxmusic/ui/library_page.dart';
import 'package:jxmusic/ui/local_page.dart';
import 'package:jxmusic/ui/search_page.dart';
import 'package:jxmusic/ui/settings_page.dart';
import 'package:jxmusic/ui/shell_page.dart';

/// 手机端顶部安全区回归测试（立项单 G1/G2，P4 实现方用例）。
///
/// 背景：Android targetSdk=36 强制 edge-to-edge，界面从屏幕 (0,0) 开始绘制，
/// 状态栏/刘海/挖孔区域必须由 App 自己避让。修复前壳层 `ShellPage` 手机分支是
/// `Column(Expanded(IndexedStack(五个 tab 页)), PlayerBar, TabBar)`，只有底部
/// TabBar 包了 `SafeArea(top:false)`，五个 tab 页顶部各自硬编码 14~20dp，
/// 没有任何顶部安全区避让 → 标题/搜索框被通知栏压住。
///
/// 本文件直接 pump 五个真实 tab 页并断言「首个可交互内容」的 globalTop：
/// - 竖屏：padding.top = 0/24/36/48dp × 宽度 320/360/393/412dp；
/// - 横屏：640×360dp 且 padding.left/right=44dp（挖孔/手势区）；
/// - 对照：桌面宽度 1280dp 下安全区容器必须原样返回（桌面布局零变化，G4）。
///
/// 说明：直接 pump `ShellPage` 会拉起 `playerServiceProvider`（media_kit Player）
/// 与 Hive 存档，widget 测试不稳定；因此这里 pump「壳层统一安全区容器 +
/// 真实页面」的组合（壳层实际接线另有 `MobileShellBody` 接线用例覆盖）。
void main() {
  late Directory hiveDir;

  setUpAll(() async {
    // LibraryPage / SettingsPage 会读 Hive（LibraryStore、深浅色主题等）。
    // widget 测试里用纯 Dart 的 Hive.init（不依赖 path_provider 插件）。
    hiveDir = await Directory.systemTemp.createTemp('jxmusic_safe_area_test');
    Hive.init(hiveDir.path);
    await Hive.openBox<dynamic>(JXConstants.hiveBoxSettings);
    await Hive.openBox<Map>(JXConstants.hiveBoxHistory);
    await Hive.openBox<Map>(JXConstants.hiveBoxPlaylists);
    await Hive.openBox<Map>(JXConstants.hiveBoxAccounts);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await hiveDir.delete(recursive: true);
    } catch (_) {}
  });

  // ---------------- 竖屏：顶部安全区 ----------------
  group('竖屏：五个 tab 页首个可交互内容必须落在状态栏/刘海下方', () {
    for (final pageCase in _pageCases) {
      testWidgets('${pageCase.name}：padding.top 0/24/36/48dp × 宽度 320/360/393/412dp',
          (tester) async {
        addTearDown(tester.view.reset);
        for (final top in const [0.0, 24.0, 36.0, 48.0]) {
          for (final screen in _portraitScreens) {
            await _pumpPage(
              tester,
              pageCase.build(),
              size: Size(screen.width, screen.height),
              padding: FakeViewPadding(top: top),
            );
            _expectSafeArea(
              tester,
              label: '${pageCase.name} @ ${screen.width}x${screen.height} '
                  'top=${top.toInt()}dp',
              content: pageCase.firstContent(),
              statusBarHeight: top,
            );
          }
        }
      });
    }
  });

  // ---------------- 横屏：左右挖孔/手势区 ----------------
  group('横屏：640x360dp 且左右安全区 44dp 时不重叠', () {
    for (final pageCase in _pageCases) {
      testWidgets('${pageCase.name}：横屏左右安全区', (tester) async {
        addTearDown(tester.view.reset);
        const size = Size(640, 360);
        const top = 24.0;
        const side = 44.0;
        await _pumpPage(
          tester,
          pageCase.build(),
          size: size,
          padding: const FakeViewPadding(top: top, left: side, right: side),
        );
        _expectSafeArea(
          tester,
          label: '${pageCase.name} @ 640x360 横屏 top=24 left/right=44dp',
          content: pageCase.firstContent(),
          statusBarHeight: top,
          leftInset: side,
          rightInset: side,
          screenWidth: size.width,
        );
      });
    }
  });

  // ---------------- 矮屏横屏：真实页面不得溢出 ----------------
  group('矮屏横屏 640x360dp：壳层 + 真实页面不出现布局溢出', () {
    testWidgets('音乐库空态可滚动、不触发 RenderFlex overflow', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(640, 360);
      tester.view.padding =
          const FakeViewPadding(top: 24, left: 44, right: 44);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicHubProvider.overrideWithValue(MusicApiHub()),
            // 空播放器（不创建 media_kit Player），否则测试环境无 libmpv。
            playerServiceProvider.overrideWith(
              (ref) => PlayerService(initPlayer: false),
            ),
          ],
          child: MaterialApp(
            theme: buildJXTheme(JXColors.primary, darkMode: false),
            home: Scaffold(
              body: MobileShellBody(
                pages: [
                  for (var i = 0; i < 5; i++)
                    i == 2 ? const LibraryPage() : const SizedBox.shrink(),
                ],
                index: 2,
                navItems: const [
                  (Icons.home_rounded, '首页'),
                  (Icons.search_rounded, '搜索'),
                  (Icons.library_music_rounded, '音乐库'),
                  (Icons.folder_rounded, '本地'),
                  (Icons.settings_rounded, '设置'),
                ],
                onTap: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      // 回归点：修复前这里空态 Column 在约 166dp 的内容区里会溢出 66px。
      expect(tester.takeException(), isNull,
          reason: '640x360 横屏 + 迷你播放条 + 底部 Tab 时音乐库空态不允许 overflow');
      expect(find.textContaining('还没有收藏的歌曲'), findsOneWidget);
    });
  });

  // ---------------- 壳层接线：删掉 MobileShellBody 里的安全区必须变红 ----------------
  group('壳层接线：MobileShellBody 对五个 tab 统一避让安全区', () {
    testWidgets('padding.top=24dp：五个 tab 内容都在 statusBar+10dp 之下', (tester) async {
      addTearDown(tester.view.reset);
      const top = 24.0;
      // IndexedStack 只挂载当前 tab，因此逐个 tab 切换验证。
      for (var i = 0; i < 5; i++) {
        await _pumpShellBody(tester,
            index: i,
            size: const Size(360, 640),
            padding: const FakeViewPadding(top: top));
        final rect = tester.getRect(find.byKey(Key('tab_$i')));
        expect(rect.top, closeTo(top + kJxMobilePageTopGap, 0.5),
            reason: '第 $i 个 tab 内容顶部 globalTop=${rect.top}，'
                '期望 ${top + kJxMobilePageTopGap}（壳层 MobilePageSafeArea 被移除？）');
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('padding.top=48dp：同样只避让一次且不重叠', (tester) async {
      addTearDown(tester.view.reset);
      const top = 48.0;
      for (var i = 0; i < 5; i++) {
        await _pumpShellBody(tester,
            index: i,
            size: const Size(393, 852),
            padding: const FakeViewPadding(top: top));
        final rect = tester.getRect(find.byKey(Key('tab_$i')));
        expect(rect.top, greaterThanOrEqualTo(top - 0.5),
            reason: '第 $i 个 tab 内容顶部 globalTop=${rect.top} '
                '落在 ${top}dp 状态栏内');
        expect(rect.top, lessThanOrEqualTo(top + kJxMobilePageTopGap + 24),
            reason: '第 $i 个 tab 内容顶部 globalTop=${rect.top} 留白过多');
        expect(tester.takeException(), isNull);
      }
    });
  });

  // ---------------- 桌面：安全区容器必须原样返回（G4 零变化） ----------------
  group('桌面布局（宽度 >= 840dp）安全区不生效，页面内边距维持原值', () {
    testWidgets('1280dp 桌面：MobilePageSafeArea 不插入 SafeArea，内容仍从 0 开始',
        (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      // 桌面窗口同样可能有系统栏 padding（这里给 24dp 故意制造风险）
      tester.view.padding = const FakeViewPadding(top: 24);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MobilePageSafeArea(
              child: SizedBox.expand(child: Text('desktop', key: Key('desk'))),
            ),
          ),
        ),
      );
      expect(find.byType(SafeArea), findsNothing,
          reason: '桌面布局不允许被 SafeArea 改变（G4 零变化）');
      expect(tester.getRect(find.byKey(const Key('desk'))).top, 0,
          reason: '桌面内容应从 0 开始，不受系统栏 padding 影响');
    });

    testWidgets('1280dp 桌面：设置页标题顶部仍是原来的 20dp', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicHubProvider.overrideWithValue(MusicApiHub()),
            // 设置页音效区 watch playerServiceProvider；不创建 media_kit Player。
            playerServiceProvider.overrideWith(
              (ref) => PlayerService(initPlayer: false),
            ),
          ],
          child: MaterialApp(
            theme: buildJXTheme(JXColors.primary, darkMode: false),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await tester.pump();
      // 修复前 ListView 顶部 padding = 20dp；桌面零变化 → 仍是 20dp。
      expect(tester.getRect(find.text('设置')).top, closeTo(20, 0.5),
          reason: '桌面设置页标题应保持 20dp 顶部内边距（G4）');
      expect(tester.takeException(), isNull);
    });
  });
}

// ======================= 测试基础设施 =======================

/// 主流手机竖屏尺寸（立项单 G2）。
const List<({double width, double height})> _portraitScreens = [
  (width: 320, height: 568), // 小屏
  (width: 360, height: 640), // 主流最小
  (width: 393, height: 852),
  (width: 412, height: 915), // 主流大屏
];

/// 一个 tab 页 + 该页「首个可交互内容」的定位方式。
class _PageCase {
  const _PageCase(this.name, this.build, this.firstContent);

  final String name;
  final Widget Function() build;
  final Finder Function() firstContent;
}

/// 五个 tab 页（顺序与 ShellPage 一致）。
///
/// 每页取「用户第一眼看到、且可交互（或紧邻交互控件）的内容」作为锚点：
/// 首页标题、搜索输入框、音乐库标题、本地音乐标题、设置标题。
List<_PageCase> get _pageCases => [
      _PageCase('首页', () => const HomePage(), () => find.text('首页')),
      _PageCase('搜索', () => const SearchPage(), () => find.byType(TextField)),
      _PageCase('音乐库', () => const LibraryPage(), () => find.text('音乐库')),
      _PageCase(
        '本地音乐',
        () => LocalPage(
          musicService: _FakeMusicService(),
          formatService: _FakeFormatService(),
          // 目录不可达 → 空态，不触发真实文件扫描
          pathsStore: _FakePathsStore(<String>[p.join('D:', 'Music')]),
          autoScan: false,
          androidOverride: false,
        ),
        () => find.text('本地音乐'),
      ),
      _PageCase('设置', () => const SettingsPage(), () => find.text('设置')),
    ];

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  required Size size,
  required FakeViewPadding padding,
}) async {
  // devicePixelRatio = 1，让 physical 尺寸/内边距与逻辑 dp 一一对应。
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  tester.view.padding = padding;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // 空聚合入口：页面不发网络请求（api == null 时直接返回）。
        musicHubProvider.overrideWithValue(MusicApiHub()),
        // 设置页音效区 watch playerServiceProvider；不创建 media_kit Player。
        playerServiceProvider.overrideWith(
          (ref) => PlayerService(initPlayer: false),
        ),
      ],
      child: MaterialApp(
        theme: buildJXTheme(JXColors.primary, darkMode: false),
        // 与 ShellPage 手机分支完全一致的组合：壳层统一安全区容器 + 真实页面。
        home: Scaffold(body: MobilePageSafeArea(child: page)),
      ),
    ),
  );
  // 有界等待：不用 pumpAndSettle（页面内有 spinner/动画时永不 settle）。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 壳层接线用例：pump 真实的 `MobileShellBody`（ShellPage 手机分支的内容区），
/// 内容区放五个可定位的占位页，迷你播放条换成空壳——不拉起 media_kit/Hive。
///
/// 这条用例的价值：如果将来有人把 `MobileShellBody` 里的 `MobilePageSafeArea`
/// 删掉，页面级用例（`_pumpPage` 自带容器）仍是绿的，但这里必红。
Future<void> _pumpShellBody(
  WidgetTester tester, {
  required int index,
  required Size size,
  required FakeViewPadding padding,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  tester.view.padding = padding;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildJXTheme(JXColors.primary, darkMode: false),
      home: Scaffold(
        body: MobileShellBody(
          pages: [
            for (var i = 0; i < 5; i++)
              Align(
                alignment: Alignment.topLeft,
                child: Text('tab_$i 内容', key: Key('tab_$i')),
              ),
          ],
          index: index,
          navItems: const [
            (Icons.home_rounded, '首页'),
            (Icons.search_rounded, '搜索'),
            (Icons.library_music_rounded, '音乐库'),
            (Icons.folder_rounded, '本地'),
            (Icons.settings_rounded, '设置'),
          ],
          onTap: (_) {},
          playerBar: const SizedBox.shrink(),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 断言内容完整落在系统栏安全区之外：不压住状态栏、不被左右挖孔/手势区遮挡、
/// 不出现 RenderFlex overflow 等布局异常。
void _expectSafeArea(
  WidgetTester tester, {
  required String label,
  required Finder content,
  required double statusBarHeight,
  double leftInset = 0,
  double rightInset = 0,
  double? screenWidth,
}) {
  expect(
    tester.takeException(),
    isNull,
    reason: '$label：出现布局异常（RenderFlex overflow / 抛异常）',
  );
  expect(content, findsOneWidget, reason: '$label：找不到该页首个可交互内容');
  final rect = tester.getRect(content);

  // 1) 顶部：内容必须在状态栏/刘海/挖孔下方，且只保留壳层统一的
  //    [kJxMobilePageTopGap] 呼吸间距（G1 核心断言）。
  //    下限：被状态栏压住 / 壳层安全区没接线时失败；
  //    上限：安全区与页面自身 padding 叠加成「双重留白」时失败。
  final minTop = statusBarHeight + kJxMobilePageTopGap - 0.5;
  final maxTop = statusBarHeight + kJxMobilePageTopGap + 24;
  expect(
    rect.top,
    greaterThanOrEqualTo(minTop),
    reason: '$label：首个可交互内容顶部 globalTop=${rect.top} 位于状态栏 '
        '${statusBarHeight}dp 安全区内（被通知栏压住）',
  );
  expect(
    rect.top,
    lessThanOrEqualTo(maxTop),
    reason: '$label：首个可交互内容顶部 globalTop=${rect.top} 距状态栏 '
        '${statusBarHeight}dp 过远（安全区与页面内边距叠加，双重留白）',
  );

  // 2) 横屏左右：内容不得落进挖孔/手势区。
  expect(
    rect.left,
    greaterThanOrEqualTo(leftInset - 0.5),
    reason: '$label：内容左侧 globalLeft=${rect.left} 落在左侧安全区 ${leftInset}dp 内',
  );
  if (screenWidth != null) {
    expect(
      rect.right,
      lessThanOrEqualTo(screenWidth - rightInset + 0.5),
      reason: '$label：内容右侧 globalRight=${rect.right} 落在右侧安全区 '
          '${rightInset}dp 内（屏幕宽 $screenWidth）',
    );
  }
}

// ======================= 测试替身（不联网、不落盘） =======================

/// 内存目录配置：不触碰 Hive/文件系统。
class _FakePathsStore extends LocalPathsStore {
  _FakePathsStore(List<String> initial) : _paths = List<String>.of(initial);

  final List<String> _paths;

  @override
  Future<List<String>> load() async => List<String>.of(_paths);

  @override
  Future<void> save(List<String> paths) async {}

  @override
  Future<List<String>> add(String path) async => List<String>.of(_paths);

  @override
  Future<List<String>> remove(String path) async => List<String>.of(_paths);

  @override
  Future<bool> contains(String path) async => _paths.contains(path);

  @override
  Future<List<String>> defaultCandidates() async => List<String>.of(_paths);
}

/// 空扫描服务：没有本地歌曲，页面进入空态。
class _FakeMusicService extends LocalMusicService {
  @override
  Future<ScanResult> scanDirectories(
    List<String> paths, {
    void Function(int found)? onProgress,
  }) async =>
      const ScanResult(songs: <Song>[]);

  @override
  Future<Song> enrichFromDecrypted(Song song, File decryptedFile) async => song;

  @override
  Future<List<String>> defaultScanPaths() async => const <String>[];
}

/// 空解密服务：不触碰 assets/缓存目录。
class _FakeFormatService extends LocalFormatService {
  _FakeFormatService() : super(decoders: const <EncryptedAudioDecoder>[]);
}
