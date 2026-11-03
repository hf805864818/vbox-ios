/// 弹幕覆盖层颜色模式渲染测试（对齐 iOS `PlayerState.danmakuColorMode`）。
///
/// 覆盖：预设色覆盖 / 原始颜色 / 随机池确定性选色（同一条弹幕稳定同色，
/// 不随逐帧重建闪烁）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/danmaku/danmaku_item.dart';
import 'package:vbox/platform/player/danmaku/danmaku_lane_engine.dart';
import 'package:vbox/platform/player/danmaku/danmaku_settings.dart';
import 'package:vbox/presentation/widgets/player/danmaku/danmaku_overlay.dart';

DanmakuRenderState _state({
  String id = 'd1',
  int color = 0x00FF0000,
}) =>
    DanmakuRenderState(
      item: DanmakuItem(
        content: '弹幕文本',
        timeMs: 0,
        color: color,
        id: id,
      ),
      lane: 0,
      x: 0,
      y: 0,
      width: 100,
    );

Color? _renderedColor(WidgetTester tester) {
  final Text text =
      tester.widget<Text>(find.text('弹幕文本'));
  return text.style?.color;
}

Widget _host(List<DanmakuRenderState> states, int colorMode) => MaterialApp(
      home: Scaffold(
        body: DanmakuOverlay(
          states: states,
          colorMode: colorMode,
        ),
      ),
    );

void main() {
  testWidgets('mode 1（白色档）：覆盖为白（默认弹幕白色语义）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(<DanmakuRenderState>[_state()], 1));
    expect(_renderedColor(tester), const Color(0xFFFFFFFF));
  });

  testWidgets('mode 2（黄色档）：覆盖为黄（对齐 iOS presetColors[2]）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(<DanmakuRenderState>[_state()], 2));
    expect(_renderedColor(tester), const Color(0xFFFFFF00));
  });

  testWidgets('mode 0（原始档）：保留弹幕自带颜色（红条 → 红）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(<DanmakuRenderState>[_state(color: 0x00FF0000)], 0),
    );
    // DanmakuItem.argb 补 alpha → 不透明红。
    expect(_renderedColor(tester), const Color(0xFFFF0000));
  });

  testWidgets('mode 6（粉色档）：覆盖为粉（对齐 iOS #FF69B4）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(<DanmakuRenderState>[_state()], 6));
    expect(_renderedColor(tester), const Color(0xFFFF69B4));
  });

  testWidgets('mode 7（随机档，默认）：从池内确定性选色且跨帧稳定',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(<DanmakuRenderState>[_state(id: 'd1')], 7),
    );
    final Color? first = _renderedColor(tester);
    expect(
      DanmakuSettings.randomColorPool
          .contains(first!.toARGB32() & 0xFFFFFF),
      isTrue,
    );

    // 重建（模拟逐帧渲染）：同一条弹幕颜色不变（确定性选色防闪烁）。
    await tester.pumpWidget(
      _host(<DanmakuRenderState>[_state(id: 'd1')], 7),
    );
    expect(_renderedColor(tester), first);

    // 不同弹幕（不同 id）命中池内另一色（分布随机）。
    await tester.pumpWidget(
      _host(
        <DanmakuRenderState>[_state(id: 'd1'), _state(id: 'another')],
        7,
      ),
    );
    final List<Text> texts = tester
        .widgetList<Text>(find.byType(Text))
        .toList();
    expect(texts, hasLength(2));
    expect(
      DanmakuSettings.randomColorPool
          .contains(texts[1].style!.color!.toARGB32() & 0xFFFFFF),
      isTrue,
    );
  });

  test('发送弹幕默认白色（对齐 iOS 发送侧 mode==0 → 16777215）', () {
    // 本地乐观上屏的弹幕走 DanmakuItem 默认色（白）；颜色档非原始时由
    // 渲染层覆盖，与 iOS「发送侧默认白」语义一致。
    const DanmakuItem item = DanmakuItem(content: 'hi', timeMs: 0);
    expect(item.argb, 0xFFFFFFFF);
  });
}
