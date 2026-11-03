/// 第 5 批 · UI-F18：播放器中央加载层。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/widgets/player/player_loading_overlay.dart';

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: Scaffold(body: child),
    );

void main() {
  group('PlayerLoadingOverlay（UI-F18）', () {
    testWidgets('展示文案 + 转圈指示器', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerLoadingOverlay(
        message: '正在缓冲首帧...',
      )));
      await tester.pump();
      expect(find.text('正在缓冲首帧...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('不拦截手势（加载层内含 IgnorePointer）', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerLoadingOverlay(
        message: '正在解析播放地址...',
      )));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(PlayerLoadingOverlay),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });
  });
}
