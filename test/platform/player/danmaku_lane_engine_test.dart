/// 批次 C · C-03：弹幕轨道引擎（车道分配 / 位置推进 / 顶底固定）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/danmaku/danmaku_item.dart';
import 'package:vbox/platform/player/danmaku/danmaku_lane_engine.dart';

void main() {
  group('DanmakuLaneEngine 滚动弹幕', () {
    test('新弹幕从右缘入场，随 t 左移', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine(
        viewportWidth: 1000,
        scrollSpeedPxPerSec: 100,
        laneHeight: 20,
        topMargin: 10,
      );
      final List<DanmakuRenderState> s0 = engine.compute(
        1000,
        const <DanmakuItem>[DanmakuItem(content: 'a', timeMs: 1000)],
      );
      expect(s0, hasLength(1));
      expect(s0.single.x, 1000);
      expect(s0.single.lane, 0);
      expect(s0.single.y, 10);

      final List<DanmakuRenderState> s1 = engine.compute(
        2000,
        const <DanmakuItem>[],
      );
      expect(s1, hasLength(1));
      expect(s1.single.x, closeTo(900, 0.01));
    });

    test('完全出屏后移除', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine(
        viewportWidth: 100,
        scrollSpeedPxPerSec: 100,
      );
      engine.compute(0, const <DanmakuItem>[DanmakuItem(content: 'x', timeMs: 0)]);
      final List<DanmakuRenderState> s =
          engine.compute(10000, const <DanmakuItem>[]);
      expect(s, isEmpty);
    });

    test('速度倍率：2x 推进距离是 1x 的两倍（对齐 iOS danmakuSpeed）', () {
      // 1x 基准。
      final DanmakuLaneEngine base = DanmakuLaneEngine(
        viewportWidth: 1000,
        scrollSpeedPxPerSec: 100,
      );
      base.compute(
        0,
        const <DanmakuItem>[DanmakuItem(content: 'a', timeMs: 0)],
      );
      final double x1 = base.compute(1000, const <DanmakuItem>[]).single.x;

      // 2x：同弹幕同间隔推进加倍。
      final DanmakuLaneEngine fast = DanmakuLaneEngine(
        viewportWidth: 1000,
        scrollSpeedPxPerSec: 100,
      )..speedMultiplier = 2.0;
      fast.compute(
        0,
        const <DanmakuItem>[DanmakuItem(content: 'a', timeMs: 0)],
      );
      final double x2 = fast.compute(1000, const <DanmakuItem>[]).single.x;

      expect(x1, closeTo(900, 0.01));
      expect(x2, closeTo(800, 0.01));
    });

    test('速度倍率下限 0.25 钳制（对齐 iOS max(speed, 0.25)）', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine(
        viewportWidth: 1000,
        scrollSpeedPxPerSec: 100,
      )..speedMultiplier = 0.1;
      expect(engine.effectiveScrollSpeed, 25);
    });

    test('车道分配：不同车道互不重叠（宽弹幕占多车道）', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine(
        viewportWidth: 200,
        laneHeight: 20,
        topMargin: 0,
        bottomMargin: 0,
      );
      // 塞满 3 条同车道易冲突 → 车道应分散。
      final List<DanmakuRenderState> s = engine.compute(
        0,
        const <DanmakuItem>[
          DanmakuItem(content: 'aaaa', timeMs: 0),
          DanmakuItem(content: 'bbbb', timeMs: 0),
          DanmakuItem(content: 'cccc', timeMs: 0),
        ],
      );
      final Set<int> lanes = s.map((DanmakuRenderState r) => r.lane).toSet();
      expect(lanes.length, greaterThan(1));
    });

    test('同车道弹幕保持最小间距', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine(
        viewportWidth: 300,
        laneHeight: 20,
        scrollSpeedPxPerSec: 100,
        minScrollGapPx: 20,
      );
      engine.compute(0, const <DanmakuItem>[DanmakuItem(content: 'x', timeMs: 0)]);
      // x 走出 3s：x 左缘 = 300 - 300 = 0，右缘 = 0 + 24 = 24。
      // 此时 y 入场：x 右缘(24) ≤ 视口右缘 - gap(300-20)，可复用同车道。
      final List<DanmakuRenderState> s = engine.compute(
        3000,
        const <DanmakuItem>[DanmakuItem(content: 'y', timeMs: 3000)],
      );
      final List<DanmakuRenderState> scroll =
          s.where((DanmakuRenderState r) => r.isScroll).toList();
      expect(scroll, hasLength(2));
      expect(scroll.first.lane, scroll.last.lane); // 同车道
      // 先入者在左、后入者在右：间距 = 后入者左缘 - 先入者右缘。
      final DanmakuRenderState first = scroll.first;
      final DanmakuRenderState last = scroll.last;
      final double gap = last.x - (first.x + first.width);
      expect(gap, greaterThanOrEqualTo(20 - 0.5));
    });
  });

  group('DanmakuLaneEngine 顶/底固定', () {
    test('顶部固定：居中显示并滞留后消失', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine(
        viewportWidth: 1000,
        topBottomLifetimeMs: 3000,
        laneHeight: 20,
        topMargin: 10,
      );
      final List<DanmakuRenderState> s0 = engine.compute(
        0,
        const <DanmakuItem>[
          DanmakuItem(content: 'top', timeMs: 0, mode: DanmakuMode.top),
        ],
      );
      expect(s0, hasLength(1));
      expect(s0.single.isScroll, isFalse);
      expect(s0.single.y, 10);
      expect(s0.single.x, greaterThan(0)); // 居中

      // 2000ms 仍在
      expect(engine.compute(2000, const <DanmakuItem>[]), hasLength(1));
      // 4000ms 超时消失
      expect(engine.compute(4000, const <DanmakuItem>[]), isEmpty);
    });

    test('底部固定：贴底车道', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine(
        viewportHeight: 400,
        laneHeight: 20,
        bottomMargin: 20,
      );
      final List<DanmakuRenderState> s = engine.compute(
        0,
        const <DanmakuItem>[
          DanmakuItem(content: 'bottom', timeMs: 0, mode: DanmakuMode.bottom),
        ],
      );
      expect(s.single.y, 400 - 20 - 20);
    });
  });

  group('DanmakuLaneEngine.reset / 参数', () {
    test('reset 清空内部状态', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine(
        viewportWidth: 100,
        scrollSpeedPxPerSec: 100,
      );
      engine.compute(0, const <DanmakuItem>[DanmakuItem(content: 'x', timeMs: 0)]);
      engine.reset();
      expect(engine.compute(0, const <DanmakuItem>[]), isEmpty);
    });

    test('estimateWidth 随字数增长', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine();
      final double w1 = engine.estimateWidth(
        const DanmakuItem(content: 'a', timeMs: 0),
      );
      final double w2 = engine.estimateWidth(
        const DanmakuItem(content: 'aaaaaaa', timeMs: 0),
      );
      expect(w2, greaterThan(w1));
    });

    test('空文本丢弃', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine();
      expect(
        engine.compute(0, const <DanmakuItem>[DanmakuItem(content: '  ', timeMs: 0)]),
        isEmpty,
      );
    });
  });
}
