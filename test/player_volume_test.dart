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

/// 播放页底部音量/倍速区回归：
/// - 应用内音量条仅桌面保留，手机端音量由系统音量键接管；
/// - 倍速按钮已按需求移除（手机/桌面都不再渲染「播放速度」入口）。
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
  testWidgets('手机端：音量条隐藏，仅剩进度条，倍速按钮已移除（音量由系统接管）',
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
    expect(find.byTooltip('播放速度'), findsNothing,
        reason: '倍速按钮已按需求移除，不应再出现播放速度入口');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant(<TargetPlatform>{
    TargetPlatform.android,
    TargetPlatform.ohos,
    TargetPlatform.iOS,
  }));

  testWidgets('桌面端：应用内音量条保留，倍速按钮已移除', (tester) async {
    await _pumpPlayerPage(tester);

    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget,
        reason: '桌面端音量图标应保留');
    expect(find.byIcon(Icons.volume_down_rounded), findsOneWidget);
    expect(
      find.byType(Slider),
      findsNWidgets(2),
      reason: '桌面端应有进度条 + 音量条两个 Slider',
    );
    expect(find.byTooltip('播放速度'), findsNothing,
        reason: '倍速按钮已按需求移除，桌面端同样不渲染');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant(<TargetPlatform>{
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  }));
}
