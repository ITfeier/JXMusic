import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/player_service.dart';
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/player/player_page.dart';
import 'package:jxmusic/ui/player/vinyl_disc.dart';

/// 播放页布局回归测试（用户真机反馈）：
/// 360x640dp 下 Expanded 给 `_AlbumArtView` 的高度不足，Column 溢出后
/// 平台 Chip「网易云」被控制区右上角「音源」按钮盖住。修复后要求：
/// 1) 360x640dp 不出现 RenderFlex overflow；
/// 2) 音源按钮只显示「音源」二字，且宽度是紧凑胶囊（64~120dp）——
///    历史回归：Container.alignment 让按钮撑满整行，变成灰色通栏；
/// 3) 封面（黑胶唱片 JXVinylDisc）按可用高度自适应，不压住控制区；
///    点击按钮仍弹「选择音源」面板。
///
/// 说明：用 `PlayerService(initPlayer: false)`（不加载 libmpv）+ 空 MusicApiHub，
/// 全程不联网；测试里 playing=false，唱片不旋转（暂停态），只做有限次 pump。
const String _longTitle = '这是一首名字特别长的歌用来验证两行标题是否会撑破播放页布局';

Song _song({required int platform}) => Song(
      id: '1',
      platform: platform,
      title: _longTitle,
      artist: '测试歌手',
      album: '测试专辑',
    );

Future<void> _pumpPlayerPage(WidgetTester tester) async {
  final service = PlayerService(initPlayer: false);
  await service.playSong(
    _song(platform: JXPlatform.netease),
    sources: [
      _song(platform: JXPlatform.qq),
      _song(platform: JXPlatform.netease),
    ],
  );
  final container = ProviderContainer(overrides: [
    musicHubProvider.overrideWithValue(MusicApiHub()),
    playerServiceProvider.overrideWith((ref) => service),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildJXTheme(JXColors.primary, darkMode: false),
        home: const PlayerPage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 卸载页面：释放唱片内部的 AnimationController，避免测试结束残留 ticker。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets('360x640dp（含 24/48dp 安全区）播放页不溢出、音源按钮不压住平台 Chip',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 1920); // 360x640dp @480dpi
    tester.view.devicePixelRatio = 3.0;
    tester.view.padding =
        const FakeViewPadding(top: 72, bottom: 144); // 状态栏 24 / 导航栏 48dp
    addTearDown(tester.view.reset);

    await _pumpPlayerPage(tester);

    expect(tester.takeException(), isNull,
        reason: '360x640dp 下播放页不允许出现 RenderFlex overflow');

    // 音源按钮只剩「音源」二字，不再带平台名/图标/箭头
    expect(find.text('音源'), findsOneWidget);
    expect(find.textContaining('音源 ·'), findsNothing);

    // 回归重点（task-5）：按钮必须是内容宽度的紧凑胶囊，不能变成整行通栏。
    // 历史 bug：Container 设了 alignment，在 bounded 父约束下撑满整行。
    final buttonFinder = find.byKey(const Key('sourceSwitchButton'));
    expect(buttonFinder, findsOneWidget);
    final buttonRect = tester.getRect(buttonFinder);
    expect(buttonRect.width, greaterThanOrEqualTo(64),
        reason: '点按宽度下限 64dp，实际 ${buttonRect.width}');
    expect(buttonRect.width, lessThanOrEqualTo(120),
        reason: '按钮宽度 ${buttonRect.width} 超过 120dp，疑似再次被撑成通栏');
    expect(buttonRect.width, lessThan(360 * 0.5),
        reason: '按钮不能横跨半屏（通栏回归）');
    expect(buttonRect.height, closeTo(26, 0.01), reason: '胶囊高度应为 26dp');
    // 右对齐保持：控制区左右 padding 各 24dp，按钮右缘应贴 360-24=336
    expect(buttonRect.right, closeTo(336, 1),
        reason: '音源按钮应右对齐，实际 right=${buttonRect.right}');

    // 平台 Chip 与控制区音源按钮不重叠（旧布局溢出时 Chip 被按钮盖住）
    final chip = tester.getRect(find.text('网易云'));
    expect(chip.bottom <= buttonRect.top + 0.5, isTrue,
        reason: 'Chip $chip 与音源按钮 $buttonRect 重叠：播放页内容仍溢出到控制区');

    // 点击仍弹出「选择音源」面板（尺寸修复不能破坏交互）
    await tester.tap(buttonFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('选择音源'), findsOneWidget, reason: '点击「音源」应弹出选择音源面板');

    // 封面已换成圆形黑胶唱片（JXVinylDisc）：宽 360 时原固定尺寸是 223.2，
    // 360x640dp 下必须按可用高度收缩，且不小于 140 下限。
    final discFinder = find.byType(JXVinylDisc);
    expect(discFinder, findsOneWidget, reason: '播放页大封面应为 JXVinylDisc');
    expect(find.byKey(const Key('playerVinylDisc')), findsOneWidget);
    final coverSide = tester.getSize(discFinder).width;
    expect(coverSide, lessThan(360 * 0.62),
        reason: '360x640dp 下封面应小于「宽度*0.62」，否则没有按高度自适应');
    expect(coverSide, greaterThanOrEqualTo(140), reason: '封面不应小于 140 下限');
    // 唱片必须是圆形：正方形外框内标签/轴孔都居中（圆的判定由 vinyl_disc_test 覆盖）
    expect(tester.getSize(discFinder).height, closeTo(coverSide, 0.01),
        reason: '黑胶唱片外框必须是正方形（内部绘制圆形盘体）');

    await _unmount(tester);
  });

  testWidgets('360x640dp 无安全区时同样不溢出', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await _pumpPlayerPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('音源'), findsOneWidget);
    // 无安全区时按钮同样必须是紧凑胶囊（宽度回归在两种安全区下都要锁）
    final buttonWidth =
        tester.getSize(find.byKey(const Key('sourceSwitchButton'))).width;
    expect(buttonWidth, inInclusiveRange(64, 120),
        reason: '无安全区下按钮宽度 $buttonWidth 超出 64~120dp 紧凑范围');

    await _unmount(tester);
  });

  group('jxPlayerCoverSize（按可用高度自适应封面）', () {
    test('桌面大窗口维持 300 上限', () {
      expect(
        jxPlayerCoverSize(maxWidth: 1280, maxHeight: 800),
        300,
        reason: '桌面观感不变：宽度*0.62 远超上限，仍取 300',
      );
    });

    test('360x640dp（Expanded 约 278）按高度收缩且不低于 140', () {
      final size = jxPlayerCoverSize(maxWidth: 360, maxHeight: 278);
      expect(size, lessThan(360 * 0.62));
      expect(size, greaterThanOrEqualTo(140));
      // 278 - 文案块预算(约 135.4) - 1dp 余量 ≈ 141.6
      expect(size, closeTo(141.6, 0.5));
    });

    test('360 宽、无安全区（Expanded 约 350）不溢出且接近原尺寸', () {
      final size = jxPlayerCoverSize(maxWidth: 360, maxHeight: 350);
      expect(size, greaterThan(200));
      expect(size, lessThanOrEqualTo(360 * 0.62));
    });

    test('高度极端不足（超大字体）时继续缩小，优先保证不溢出', () {
      final size = jxPlayerCoverSize(
        maxWidth: 360,
        maxHeight: 306,
        textScaler: const TextScaler.linear(2),
      );
      expect(size, lessThan(140), reason: '文案已占满时允许封面小于下限');
      expect(size, closeTo(83.8, 0.5));
    });

    test('高度小到文案都放不下时返回 0（UI 隐藏封面）', () {
      expect(jxPlayerCoverSize(maxWidth: 360, maxHeight: 120), 0);
    });

    test('间距：矮屏 12、常规 40', () {
      expect(jxPlayerCoverGap(278), 12);
      expect(jxPlayerCoverGap(350), 12);
      expect(jxPlayerCoverGap(800), 40);
    });
  });
}
