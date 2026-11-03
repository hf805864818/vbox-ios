/// 品牌闪屏单测（批次 L · L-壳1）。
///
/// 素材：与 iOS 同源的 4 张字母 PNG + swoosh（1:1 复刻 iOS 布局常量）。
/// 关键回归点：飞入聚合 / swoosh 扫入 / 发光 / 呼吸循环各阶段渲染不抛异常、无溢出。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/widgets/brand/vbox_splash_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('品牌闪屏渲染无溢出（字母图 + swoosh）', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: VboxSplashView()));

    // 推进至字母聚合 / swoosh / 发光 / 呼吸循环各阶段。
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);

    // 卸载以释放循环动画 Ticker 与内部定时器。
    await tester.pumpWidget(const SizedBox.shrink());
  });
}