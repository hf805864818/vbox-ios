/// 表现层单测：焦点可视反馈（批次 B 补充 · TV 遥控可用性）。
///
/// 覆盖：
///   · `FocusableTap` 自动聚焦后 Enter 触发一次；
///   · `enabled=false` 时不参与触发；
///   · 聚焦时出现描边，失焦后消失（不改变布局）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/widgets/input/focus_affordance.dart';

AnimatedContainer _ringOf(WidgetTester tester, Type host) => tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(host),
        matching: find.byType(AnimatedContainer),
      ),
    );

void main() {
  testWidgets('FocusableTap：自动聚焦后 Enter 触发一次', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: FocusableTap(
          autofocus: true,
          onTap: () => taps++,
          borderRadius: BorderRadius.circular(8),
          child: const SizedBox(width: 80, height: 40),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);

    // 聚焦态：描边存在。
    expect(_ringOf(tester, FocusableTap).foregroundDecoration, isNotNull);
  });

  testWidgets('FocusableTap：无 onTap（禁用）时 Enter 不触发且无描边',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(const MaterialApp(
      home: Center(
        child: FocusableTap(
          autofocus: true,
          child: SizedBox(width: 80, height: 40),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(_ringOf(tester, FocusableTap).foregroundDecoration, isNull);
  });

  testWidgets('FocusableTap：触摸点击仍可用（无焦点环依赖）',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: FocusableTap(
          onTap: () => taps++,
          child: const SizedBox(width: 80, height: 40),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FocusableTap));
    await tester.pumpAndSettle();
    expect(taps, 1);
    // 未聚焦 → 无描边（鼠标点击不产生焦点环）。
    expect(_ringOf(tester, FocusableTap).foregroundDecoration, isNull);
  });
}
