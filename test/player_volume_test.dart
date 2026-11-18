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

/// 手机端应用内音量条移除（音量由系统音量键接管）：
/// - 手机平台（android/ohos/ios）：音量图标/滑块不渲染，仅剩进度条，
///   倍速按钮保留且右对齐；
/// - 桌面平台（windows/macOS/linux）：应用内音量条保留，观感不变。
///
/// 复用 player_page_layout_test 的不联网 harness：
/// `PlayerService(initPlayer: false)`（不加载 libmpv）+ 空 MusicApiHub。
/// 平台差异用 TargetPlatformVariant 驱动（框架负责设置/还原，
/// 避免 debugDefaultTargetPlatformOverride 手动改被 _verifyInvariants 拦截）。
Song _song({required int platform}) => Song(
      id: '1',
      platform: platform,
      title: '测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
    );

Future<void> _pumpPlayerPage(WidgetTester tester) async {
  final service = PlayerService(initPlayer: false);
  await service.playSong(
    _song(platform: JXPlatform.netease),
    sources: [_song(platform: JXPlatform.netease)],
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

void main() {
  testWidgets('手机端：音量条隐藏，仅剩进度条，倍速按钮保留（音量由系统接管）',
      (tester) async {
    await _pumpPlayerPage(tester);

    expect(find.byIcon(Icons.volume_up_rounded), findsNothing,
        reason: '手机端不应渲染音量图标');
    expect(find.byIcon(Icons.volume_down_rounded), findsNothing);
    expect(
      find.byType(Slider),
      findsOneWidget,
      reason: '手机端只剩进度条一个 Slider，应用内音量滑块应移除',
    );
    expect(find.byTooltip('播放速度'), findsOneWidget,
        reason: '倍速按钮不受音量条移除影响');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant(<TargetPlatform>{
    TargetPlatform.android,
    TargetPlatform.ohos,
    TargetPlatform.iOS,
  }));

  testWidgets('桌面端：应用内音量条保留（图标 + 滑块 + 倍速）', (tester) async {
    await _pumpPlayerPage(tester);

    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget,
        reason: '桌面端音量图标应保留');
    expect(find.byIcon(Icons.volume_down_rounded), findsOneWidget);
    expect(
      find.byType(Slider),
      findsNWidgets(2),
      reason: '桌面端应有进度条 + 音量条两个 Slider',
    );
    expect(find.byTooltip('播放速度'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant(<TargetPlatform>{
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  }));
}
