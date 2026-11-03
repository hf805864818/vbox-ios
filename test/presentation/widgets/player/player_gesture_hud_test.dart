/// 第 3 批 · UI-F1：手势提示浮层（亮度 / 音量 / 快进快退）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/gesture/gesture_control.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/widgets/player/gesture_hud.dart';

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: Scaffold(body: child),
    );

void main() {
  group('PlayerGestureHud（UI-F1）', () {
    testWidgets('亮度：图标 + 百分比 + 进度条', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerGestureHud(
        adjustment: GestureAdjustment(
          mode: GestureMode.brightness,
          brightness: 0.62,
          label: '亮度 62%',
        ),
      )));
      expect(find.byIcon(Icons.brightness_6_rounded), findsOneWidget);
      expect(find.text('亮度 62%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('音量：图标 + 百分比', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerGestureHud(
        adjustment: GestureAdjustment(
          mode: GestureMode.volume,
          volume: 0.3,
          label: '音量 30%',
        ),
      )));
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      expect(find.text('音量 30%'), findsOneWidget);
    });

    testWidgets('快进快退：无进度条，仅时长文案', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerGestureHud(
        adjustment: GestureAdjustment(
          mode: GestureMode.seek,
          seekSeconds: 160,
          label: '02:40 / 16:40',
        ),
      )));
      expect(find.byIcon(Icons.fast_forward_rounded), findsOneWidget);
      expect(find.text('02:40 / 16:40'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });
}
