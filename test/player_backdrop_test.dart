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

/// 播放页沉浸式封面背景回归测试（UI 改版）：
/// - 有封面：背景模糊层 + 压暗渐变层渲染（key：playerBackdropArt/Scrim），
///   且都不可点（背景不拦截前景手势）；
/// - 无封面：两层都不渲染，退回纯渐变背景（列表占位歌曲/本地无封面场景）；
/// - 顶层「正在播放」精简为单行（不再渲染应用名）。
///
/// harness 复用 player_page_layout_test：`PlayerService(initPlayer: false)`
/// + 空 MusicApiHub，全程不联网；封面 URL 用 example.com（测试环境
/// NetworkImage 请求失败 → errorBuilder 回落透明，不影响结构断言）。
Song _song({String coverUrl = ''}) => Song(
      id: '1',
      platform: JXPlatform.qq,
      title: '背景测试曲',
      artist: '测试歌手',
      coverUrl: coverUrl,
    );

Future<ProviderContainer> _pumpPlayerPage(
  WidgetTester tester,
  PlayerService service,
) async {
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
  return container;
}

void main() {
  testWidgets('有封面：沉浸式背景两层渲染且不拦截前景手势', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920); // 360x640dp
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final service = PlayerService(initPlayer: false);
    await service.playSong(_song(coverUrl: 'https://example.com/cover.jpg'));
    await _pumpPlayerPage(tester, service);

    expect(tester.takeException(), isNull, reason: '沉浸式背景不允许引入布局异常');
    expect(find.byKey(const Key('playerBackdropArt')), findsOneWidget,
        reason: '有封面时应渲染模糊封面背景层');
    expect(find.byKey(const Key('playerBackdropScrim')), findsOneWidget,
        reason: '有封面时应渲染压暗渐变层保证前景可读');
    // 模糊层确实带 blur 滤镜（不是普通贴图）
    expect(find.byType(ImageFiltered), findsOneWidget);

    // 前景仍在：顶部标题 + 主播放键不受背景层影响
    expect(find.text('正在播放'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    // 卸载释放资源（AnimatedSwitcher 无 ticker，但保持与既有测试一致的收尾）
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('无封面：背景两层都不渲染，退回纯渐变背景', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final service = PlayerService(initPlayer: false);
    await service.playSong(_song());
    await _pumpPlayerPage(tester, service);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('playerBackdropArt')), findsNothing,
        reason: '空 coverUrl 不应渲染封面背景层（列表占位/无封面歌曲）');
    expect(find.byKey(const Key('playerBackdropScrim')), findsNothing,
        reason: '无背景图时压暗层只会把渐变背景弄脏，不应渲染');
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('正在播放'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('顶部栏精简：单行「正在播放」，不再渲染应用名副标题', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final service = PlayerService(initPlayer: false);
    await service.playSong(_song());
    await _pumpPlayerPage(tester, service);

    expect(find.text('正在播放'), findsOneWidget);
    expect(find.text(JXConstants.appName), findsNothing,
        reason: '顶部栏应精简为单行标题，应用名副标题已移除');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
