// 冒烟测试：原模板 counter 测试引用了不存在的 MyApp（模板残留），
// 这里换成对基础组件 GlassButton 的真实冒烟验证。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/ui/glass.dart';

void main() {
  testWidgets('GlassButton 渲染文本并响应点击', (WidgetTester tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassButton(
              text: '冒烟按钮',
              onPressed: () => tapped++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('冒烟按钮'), findsOneWidget);

    await tester.tap(find.text('冒烟按钮'));
    await tester.pump();
    expect(tapped, 1);
  });
}
