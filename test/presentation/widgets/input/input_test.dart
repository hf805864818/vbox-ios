/// 输入适配层单测（批次 A · A-09）。
///
/// 验收：`docs/第2轮开发计划_功能补全_v2.6.md` §3.4 ——
///   [FocusRing]（遥控：主色描边 + 放大）· [HoverAffordance]（鼠标：hover 底色）·
///   [InputShortcuts]（键盘：空格 / 方向键 / Esc / 回车）· [TenFootScaler]（TV：1.2–1.5×）。
/// 原则：只加反馈层，不改版式；门控按 `UiFormController.modality`。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';
import 'package:vbox/presentation/widgets/input/input.dart';

/// 以指定输入模态承载被测组件。
Widget _host(Widget child, {InputModality modality = InputModality.touch}) {
  final UiFormEnv env = switch (modality) {
    InputModality.remote => const UiFormEnv(
        isTv: true,
        hasDpad: true,
        hasTouch: false,
      ),
    InputModality.mouseKeyboard => const UiFormEnv(
        isDesktop: true,
        hasPointer: true,
        hasTouch: false,
      ),
    InputModality.touch => const UiFormEnv(),
  };
  return ChangeNotifierProvider<UiFormController>.value(
    value: UiFormController(env: env),
    child: MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Border _ringBorder(WidgetTester tester) {
  final DecoratedBox box = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.byType(FocusRing),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
  final BoxDecoration deco = box.decoration as BoxDecoration;
  return deco.border! as Border;
}

void main() {
  group('FocusRing（遥控焦点环）', () {
    testWidgets('遥控模态聚焦：主色描边 + 放大', (WidgetTester tester) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _host(
          FocusRing(
            focusNode: node,
            child: const SizedBox(width: 100, height: 100),
          ),
          modality: InputModality.remote,
        ),
      );

      node.requestFocus();
      await tester.pump();

      expect(_ringBorder(tester).top.color, isNot(Colors.transparent));
      final AnimatedScale scale =
          tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale.scale, closeTo(1.04, 0.001));
    });

    testWidgets('遥控模态失焦：描边透明', (WidgetTester tester) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _host(
          FocusRing(
            focusNode: node,
            child: const SizedBox(width: 100, height: 100),
          ),
          modality: InputModality.remote,
        ),
      );
      expect(_ringBorder(tester).top.color, Colors.transparent);
    });

    testWidgets('触摸模态聚焦：不显示焦点环（只加反馈层，不改版式）', (WidgetTester tester) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _host(
          FocusRing(
            focusNode: node,
            child: const SizedBox(width: 100, height: 100),
          ),
          modality: InputModality.touch,
        ),
      );

      node.requestFocus();
      await tester.pump();

      expect(_ringBorder(tester).top.color, Colors.transparent);
      final AnimatedScale scale =
          tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale.scale, 1.0);
    });
  });

  group('HoverAffordance（鼠标悬停）', () {
    testWidgets('鼠标键盘模态：hover 显示主色底色', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const HoverAffordance(child: SizedBox(width: 100, height: 100)),
          modality: InputModality.mouseKeyboard,
        ),
      );

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture.moveTo(tester.getCenter(find.byType(HoverAffordance)));
      await tester.pumpAndSettle();

      final AnimatedContainer box =
          tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
      final Color? color = (box.decoration! as BoxDecoration).color;
      expect(color, isNotNull);
      expect(color!.a, greaterThan(0));
    });

    testWidgets('触摸模态：hover 不响应（无底色）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const HoverAffordance(child: SizedBox(width: 100, height: 100)),
          modality: InputModality.touch,
        ),
      );

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture.moveTo(tester.getCenter(find.byType(HoverAffordance)));
      await tester.pumpAndSettle();

      final AnimatedContainer box =
          tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
      final Color? color = (box.decoration! as BoxDecoration).color;
      expect(color, isNotNull);
      expect(color!.a, 0);
    });
  });

  group('InputShortcuts（键盘快捷键）', () {
    testWidgets('鼠标键盘模态：空格触发播放/暂停', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        _host(
          InputShortcuts(
            onPlayPause: () => calls++,
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
          modality: InputModality.mouseKeyboard,
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(calls, 1);
    });

    testWidgets('鼠标键盘模态：方向键 / Esc / 回车分别触发', (WidgetTester tester) async {
      final List<String> hits = <String>[];
      await tester.pumpWidget(
        _host(
          InputShortcuts(
            onSeekBack: () => hits.add('back'),
            onSeekForward: () => hits.add('fwd'),
            onBack: () => hits.add('esc'),
            onConfirm: () => hits.add('enter'),
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
          modality: InputModality.mouseKeyboard,
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(hits, <String>['back', 'fwd', 'esc', 'enter']);
    });

    testWidgets('触摸模态：不拦截按键', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        _host(
          InputShortcuts(
            onPlayPause: () => calls++,
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
          modality: InputModality.touch,
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(calls, 0);
    });
  });

  group('TenFootScaler（十英尺缩放）', () {
    testWidgets('遥控模态：textScaler 放大 1.35×', (WidgetTester tester) async {
      double? scale;
      await tester.pumpWidget(
        _host(
          TenFootScaler(
            child: Builder(
              builder: (BuildContext context) {
                scale = MediaQuery.textScalerOf(context).scale(1.0);
                return const SizedBox();
              },
            ),
          ),
          modality: InputModality.remote,
        ),
      );
      expect(scale, closeTo(1.35, 0.001));
    });

    testWidgets('触摸模态：不缩放（1.0）', (WidgetTester tester) async {
      double? scale;
      await tester.pumpWidget(
        _host(
          TenFootScaler(
            child: Builder(
              builder: (BuildContext context) {
                scale = MediaQuery.textScalerOf(context).scale(1.0);
                return const SizedBox();
              },
            ),
          ),
          modality: InputModality.touch,
        ),
      );
      expect(scale, 1.0);
    });

    testWidgets('档位越界：clamp 到 [1.2, 1.5]', (WidgetTester tester) async {
      double? scale;
      await tester.pumpWidget(
        _host(
          TenFootScaler(
            scale: 2.0,
            child: Builder(
              builder: (BuildContext context) {
                scale = MediaQuery.textScalerOf(context).scale(1.0);
                return const SizedBox();
              },
            ),
          ),
          modality: InputModality.remote,
        ),
      );
      expect(scale, closeTo(1.5, 0.001));
    });
  });
}