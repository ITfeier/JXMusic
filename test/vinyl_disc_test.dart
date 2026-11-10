import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/lyric.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/player_service.dart';
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/player/player_page.dart';
import 'package:jxmusic/ui/player/vinyl_disc.dart';

/// 黑胶唱片 + 播放页歌词三态测试：
/// 1) 结构/尺寸比例：根/沟槽/标签/轴孔 Key 齐全，标签 ≈0.52×size、轴孔 ≈0.05×size；
/// 2) spinning=true 时连续两帧 Transform 不同（播放中旋转）；
/// 3) spinning=false 时连续两帧相同，且从播放切到暂停时停住当前角度、不跳回 0；
/// 4) 封面为空时中心标签有音符兜底；
/// 5) 播放页歌词三态（PRD R2）：loading / empty / error+重试 / ready，
///    用可控 `lyricsResolver` 注入 `PlayerService(initPlayer: false)`。
Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: child),
    ),
  );
}

/// 取唱片旋转矩阵（RotationTransition 的 Transform 是根 Key 下的第一个 Transform，
/// 旋转由它驱动；比较 matrix 是否变化即可验证「转 / 不转」）。
///
/// 注意：Flutter 3.47 的 RenderTransform 没有 transform getter（Matrix4 可变），
/// 因此从 widget 层读取 `Transform.transform`。
Matrix4 _discRotationMatrix(WidgetTester tester) {
  final finder = find.descendant(
    of: find.byKey(const Key('playerVinylDisc')),
    matching: find.byType(Transform),
  );
  expect(finder, findsWidgets, reason: '唱片内部应有 RotationTransition 的 Transform');
  return tester.widget<Transform>(finder.first).transform.clone();
}

bool _sameMatrix(Matrix4 a, Matrix4 b) => listEquals(a.storage, b.storage);

// ---------------------------------------------------------------------------
// 播放页歌词三态测试辅助（PRD R2）
// ---------------------------------------------------------------------------

Song _lyricSong() => Song(
      id: 'lyric-1',
      platform: JXPlatform.qq,
      title: '歌词状态测试曲',
      artist: '测试歌手',
      album: '测试专辑',
      // 给直链，避免切歌时走 urlResolver；歌词加载与音频打开解耦（T1 R1.3）
      audioUrl: 'https://example.com/test.mp3',
    );

const List<LyricLine> _testLyricLines = [
  LyricLine(0, '第一行歌词'),
  LyricLine(1000, '第二行歌词'),
  LyricLine(2000, '第三行歌词'),
];

/// 以 360x640dp 打开播放页并切到歌词面板，返回注入的 [PlayerService]。
Future<PlayerService> _pumpPlayerPageLyrics(
  WidgetTester tester, {
  required Future<List<LyricLine>> Function(Song song) resolver,
}) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3.0;
  tester.view.padding = const FakeViewPadding(top: 72, bottom: 144);
  addTearDown(tester.view.reset);

  final service = PlayerService(initPlayer: false, lyricsResolver: resolver);
  await service.playSong(_lyricSong());
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
  // 切到歌词面板（AnimatedSwitcher 300ms 过渡）
  await tester.tap(find.byIcon(Icons.lyrics_rounded));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return service;
}

void main() {
  testWidgets('圆盘结构：根/沟槽/标签/轴孔 Key 与尺寸比例', (tester) async {
    await tester.pumpWidget(
      _host(const JXVinylDisc(coverUrl: '', size: 300)),
    );
    await tester.pump();

    // 根节点：正方形唱片，尺寸由调用方给定
    final disc = find.byKey(const Key('playerVinylDisc'));
    expect(disc, findsOneWidget);
    expect(tester.getSize(disc), const Size(300, 300));

    // 沟槽绘制层（CustomPaint）
    expect(find.byKey(const Key('vinylGrooves')), findsOneWidget);

    // 中心标签：直径 ≈ 0.52×size，且与盘体同心
    final label = find.byKey(const Key('vinylLabel'));
    expect(label, findsOneWidget);
    expect(tester.getSize(label).width, closeTo(300 * 0.52, 0.01));
    expect(tester.getCenter(label), tester.getCenter(disc));

    // 中心轴孔：直径 ≈ 0.05×size，居中
    final hole = find.byKey(const Key('vinylHole'));
    expect(hole, findsOneWidget);
    expect(tester.getSize(hole).width, closeTo(300 * 0.05, 0.01));
    expect(tester.getCenter(hole), tester.getCenter(disc));

    // 空封面 → 中心标签音符兜底（盘体仍完整）
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
  });

  testWidgets('spinning=true：连续两帧 Transform 不同（播放中旋转）', (tester) async {
    await tester.pumpWidget(
      _host(const JXVinylDisc(coverUrl: '', size: 200, spinning: true)),
    );
    await tester.pump();

    final first = _discRotationMatrix(tester);
    await tester.pump(const Duration(milliseconds: 500));
    final second = _discRotationMatrix(tester);

    expect(_sameMatrix(first, second), isFalse, reason: '播放中两帧旋转矩阵应不同');

    // 停掉动画，避免测试结束时残留 ticker
    await tester.pumpWidget(
      _host(const JXVinylDisc(coverUrl: '', size: 200)),
    );
    await tester.pump();
  });

  testWidgets('spinning=false：连续两帧相同（暂停静止）', (tester) async {
    await tester.pumpWidget(
      _host(const JXVinylDisc(coverUrl: '', size: 200)),
    );
    await tester.pump();

    final first = _discRotationMatrix(tester);
    await tester.pump(const Duration(milliseconds: 500));
    final second = _discRotationMatrix(tester);

    expect(_sameMatrix(first, second), isTrue, reason: '暂停时旋转矩阵不应变化');
  });

  testWidgets('播放 → 暂停：停在当前角度，不跳回 0；恢复播放继续转', (tester) async {
    await tester.pumpWidget(
      _host(const JXVinylDisc(coverUrl: '', size: 200, spinning: true)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    final running = _discRotationMatrix(tester);
    // 同一 widget 位置重建为 spinning=false → 状态保留、动画 stop
    await tester.pumpWidget(
      _host(const JXVinylDisc(coverUrl: '', size: 200)),
    );
    await tester.pump();
    final atPause = _discRotationMatrix(tester);
    expect(_sameMatrix(running, atPause), isTrue, reason: '暂停瞬间应保持当前角度，不重置');

    await tester.pump(const Duration(milliseconds: 700));
    final stillPaused = _discRotationMatrix(tester);
    expect(_sameMatrix(atPause, stillPaused), isTrue, reason: '暂停后角度不应继续变化');

    // 恢复播放：从当前角度继续，而不是回到 0
    await tester.pumpWidget(
      _host(const JXVinylDisc(coverUrl: '', size: 200, spinning: true)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final resumed = _discRotationMatrix(tester);
    expect(_sameMatrix(atPause, resumed), isFalse, reason: '恢复播放后应继续旋转');

    await tester.pumpWidget(
      _host(const JXVinylDisc(coverUrl: '', size: 200)),
    );
    await tester.pump();
  });

  // -------------------------------------------------------------------------
  // 歌词三态（PRD R2，S4）
  // -------------------------------------------------------------------------

  testWidgets('歌词 loading：显示转圈+「歌词加载中…」，绝不显示「暂无歌词」', (tester) async {
    final completer = Completer<List<LyricLine>>();
    await _pumpPlayerPageLyrics(tester, resolver: (_) => completer.future);

    expect(find.byKey(const Key('lyricsLoading')), findsOneWidget);
    expect(find.text('歌词加载中…'), findsOneWidget);
    expect(find.byKey(const Key('lyricsEmpty')), findsNothing);
    expect(find.text('暂无歌词'), findsNothing, reason: '加载中不得显示「暂无歌词」');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 请求完成 → ready：既有滚动高亮列表
    completer.complete(_testLyricLines);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('lyricsLoading')), findsNothing);
    expect(find.text('第一行歌词'), findsOneWidget);
    expect(find.text('第三行歌词'), findsOneWidget);
  });

  testWidgets('歌词 empty：显示「暂无歌词」（无重试按钮）', (tester) async {
    await _pumpPlayerPageLyrics(
      tester,
      resolver: (_) async => const <LyricLine>[],
    );

    expect(find.byKey(const Key('lyricsEmpty')), findsOneWidget);
    expect(find.text('暂无歌词'), findsOneWidget);
    expect(find.byKey(const Key('lyricsLoading')), findsNothing);
    expect(find.byKey(const Key('lyricsRetryButton')), findsNothing);
  });

  testWidgets('歌词 error：显示「歌词加载失败」+ 重试按钮，点重试后变 ready', (tester) async {
    final retryCompleter = Completer<List<LyricLine>>();
    var calls = 0;
    await _pumpPlayerPageLyrics(tester, resolver: (_) {
      calls++;
      if (calls == 1) {
        // 首次请求失败（模拟网络/接口异常）
        return Future<List<LyricLine>>.error(Exception('模拟歌词接口失败'));
      }
      // 重试请求挂起，便于稳定断言 loading 中间态
      return retryCompleter.future;
    });

    expect(calls, 1);
    expect(find.text('歌词加载失败'), findsOneWidget);
    expect(find.byKey(const Key('lyricsRetryButton')), findsOneWidget);
    expect(find.text('暂无歌词'), findsNothing, reason: '失败不得伪装成无歌词');

    // 点击重试 → 重新请求（loading）→ 完成 → ready
    await tester.tap(find.byKey(const Key('lyricsRetryButton')));
    await tester.pump();
    expect(calls, 2, reason: '重试应真正重新请求歌词');
    expect(find.byKey(const Key('lyricsLoading')), findsOneWidget);
    expect(find.text('歌词加载失败'), findsNothing);

    retryCompleter.complete(_testLyricLines);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('lyricsLoading')), findsNothing);
    expect(find.byKey(const Key('lyricsRetryButton')), findsNothing);
    expect(find.text('第一行歌词'), findsOneWidget);
  });
}
