import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/theme.dart';
import 'package:jxmusic/ui/glass.dart';

/// 底部悬浮玻璃通知条回归测试（真机需求：底部弹出的提示条做成悬浮玻璃
/// 风格，与全 app 液态玻璃语言一致；此前是 Material 默认的贴边扁平暗色条，
/// 且 +41 误改过底部导航布局，本需求实为「通知条悬浮」而非「底栏悬浮」）。
void main() {
  Future<void> pumpNoticeHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildJXTheme(JXColors.primary, darkMode: false),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => jxShowNotice(context, '测试通知内容'),
                child: const Text('显示通知'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('jxShowNotice：悬浮玻璃胶囊（脱离屏幕边缘 + 模糊本体 + 浮动行为）',
      (tester) async {
    await pumpNoticeHost(tester);

    await tester.tap(find.text('显示通知'));
    await tester.pump();
    await tester.pumpAndSettle(); // 入场动画完成

    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.behavior, SnackBarBehavior.floating,
        reason: '必须为浮动行为（悬浮），不能是贴边固定式');
    expect(bar.elevation, 0, reason: '投影由玻璃胶囊自带，SnackBar 外壳无投影');
    expect(bar.backgroundColor, Colors.transparent,
        reason: '外壳透明，玻璃本体在内容里自绘');

    // 玻璃本体：背景模糊 + 描边胶囊
    expect(
      find.descendant(
          of: find.byType(SnackBar), matching: find.byType(BackdropFilter)),
      findsOneWidget,
      reason: '通知条应有背景模糊玻璃本体',
    );
    expect(find.text('测试通知内容'), findsOneWidget);

    // 悬浮几何：脱离左右/底部屏幕边缘（margin 16/16/12）
    final pill = tester.getRect(find.descendant(
        of: find.byType(SnackBar), matching: find.byType(BackdropFilter)));
    expect(pill.left, closeTo(16, 0.5), reason: '通知条应脱离左边缘悬浮');
    expect(pill.right, closeTo(360 - 16, 0.5), reason: '通知条应脱离右边缘悬浮');
    expect(pill.bottom, closeTo(640 - 12, 0.5), reason: '通知条应脱离底边缘悬浮');

    // 默认 4s 到时自动消失（顺带消掉计时器，避免测试遗留 pending timer）
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing, reason: '默认时长到后应自动消失');
  });

  testWidgets('jxShowNotice 自定义时长生效（到时自动消失）', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildJXTheme(JXColors.primary, darkMode: false),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => jxShowNotice(context, '短通知',
                    duration: const Duration(milliseconds: 100)),
                child: const Text('显示通知'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示通知'));
    await tester.pump(); // 入场动画首帧，通知已在树中
    expect(find.byType(SnackBar), findsOneWidget, reason: '自定义时长内应可见');

    await tester.pump(const Duration(milliseconds: 300)); // 入场完成 + 越过 100ms 时长
    await tester.pumpAndSettle(); // 退场动画完成
    expect(find.byType(SnackBar), findsNothing, reason: '到时后应自动消失');
  });
}
