/// 平台层：弹幕轨道引擎（批次 C · C-03，纯 Dart，可单测）。
///
/// 职责：给定播放时刻与一批弹幕，输出「此刻应渲染的弹幕」及各自
/// 车道 / 横向位置。渲染层（[DanmakuOverlay]）只负责按结果摆放 Widget。
///
/// 算法：
///  - 滚动弹幕：自右向左匀速。按弹幕宽度（估算自文本长度）分配车道，
///    同车道保证首尾不重叠；越过左边界即出屏移除。
///  - 顶 / 底固定弹幕：固定车道，显示 [topBottomLifetimeMs] 后消失。
library;

import 'dart:math' as math;

import 'danmaku_item.dart';

/// 单条弹幕的渲染状态（由引擎在某一时刻产出）。
class DanmakuRenderState {
  /// 构造。
  const DanmakuRenderState({
    required this.item,
    required this.lane,
    required this.x,
    required this.y,
    required this.width,
    this.isScroll = true,
  });

  /// 弹幕本体。
  final DanmakuItem item;

  /// 车道序号。
  final int lane;

  /// 横向位置（px；滚动弹幕为左缘 x，固定弹幕为居中后的左缘）。
  final double x;

  /// 纵向位置（px；车道顶部 y）。
  final double y;

  /// 弹幕估算宽度（px）。
  final double width;

  /// 是否滚动弹幕（否则为顶/底固定）。
  final bool isScroll;
}

/// 弹幕轨道引擎：分配车道并计算渲染位置（C-03 渲染核心）。
class DanmakuLaneEngine {
  /// 构造。
  DanmakuLaneEngine({
    this.viewportWidth = 1080,
    this.viewportHeight = 1920,
    this.scrollSpeedPxPerSec = 160,
    this.laneHeight = 26,
    this.topBottomLifetimeMs = 4000,
    this.minScrollGapPx = 20,
    this.topMargin = 40,
    this.bottomMargin = 40,
  });

  /// 视口宽度（px）。
  final double viewportWidth;

  /// 视口高度（px）。
  final double viewportHeight;

  /// 滚动速度（px/s）。
  final double scrollSpeedPxPerSec;

  /// 车道高（px）。
  final double laneHeight;

  /// 顶/底固定弹幕显示时长。
  final int topBottomLifetimeMs;

  /// 同车道滚动弹幕最小间距。
  final double minScrollGapPx;

  /// 顶部 / 底部留白（px）。
  final double topMargin;
  final double bottomMargin;

  /// 弹幕滚动速度倍率（对齐 iOS `PlayerState.danmakuSpeed`：0.5/0.75/1.0/1.5/2.0，
  /// 默认 1.0；iOS 渲染端 `duration = baseDuration / max(speed, 0.25)`，等价于
  /// 有效速度 = 基速 × max(倍率, 0.25)，倍率越大滚得越快）。面板可实时调整。
  double speedMultiplier = 1.0;

  /// 有效滚动速度（px/s；含速度倍率钳制，语义对齐 iOS `max(speed, 0.25)`）。
  double get effectiveScrollSpeed =>
      scrollSpeedPxPerSec * math.max(speedMultiplier, 0.25);

  /// 滚动车道数。
  int get scrollLaneCount =>
      math.max(1, ((viewportHeight - topMargin - bottomMargin) / laneHeight).floor());

  /// 估算弹幕宽度（px）：按字号与字数粗估。
  double estimateWidth(DanmakuItem item) {
    final int runes = item.content.runes.length;
    return runes * item.sizePx + 8;
  }

  /// 计算某时刻的渲染状态列表。
  ///
  /// [items] 为**即将在此刻出现**的弹幕（播放器在滚动窗口内喂入）；
  /// 引擎维护内部已出场弹幕队列（[reset] 清空）。
  List<DanmakuRenderState> compute(
    int nowMs,
    List<DanmakuItem> items,
  ) {
    _expire(nowMs);
    final List<DanmakuRenderState> out = <DanmakuRenderState>[];

    // 1. 已出场滚动弹幕：推进位置，越界即移除。
    final double speed = effectiveScrollSpeed;
    final List<_ActiveScroll> kept = <_ActiveScroll>[];
    for (final _ActiveScroll a in _scrolls) {
      final double x = a.startX - (nowMs - a.startMs) / 1000 * speed;
      if (x + a.width < 0) continue; // 完全出屏
      kept.add(a);
      out.add(DanmakuRenderState(
        item: a.item,
        lane: a.lane,
        x: x,
        y: topMargin + a.lane * laneHeight,
        width: a.width,
      ));
    }
    _scrolls..clear()..addAll(kept);

    // 2. 顶/底固定弹幕：过期移除。
    final List<_ActiveFixed> keptFixed = <_ActiveFixed>[];
    for (final _ActiveFixed f in _fixeds) {
      if (nowMs - f.startMs >= topBottomLifetimeMs) continue;
      keptFixed.add(f);
      final double x = _centerX(f.width);
      out.add(DanmakuRenderState(
        item: f.item,
        lane: f.lane,
        x: x,
        y: f.item.mode == DanmakuMode.bottom
            ? viewportHeight - bottomMargin - laneHeight * (f.lane + 1)
            : topMargin + f.lane * laneHeight,
        width: f.width,
        isScroll: false,
      ));
    }
    _fixeds..clear()..addAll(keptFixed);

    // 3. 新弹幕入场。
    for (final DanmakuItem item in items) {
      if (item.isEmpty) continue;
      final double w = estimateWidth(item);
      if (item.mode == DanmakuMode.scroll) {
        final int lane = _pickScrollLane(w, nowMs);
        _scrolls.add(_ActiveScroll(
          item,
          lane,
          w,
          startMs: nowMs,
          startX: viewportWidth,
        ));
        out.add(DanmakuRenderState(
          item: item,
          lane: lane,
          x: viewportWidth,
          y: topMargin + lane * laneHeight,
          width: w,
        ));
      } else {
        final int lane = _pickFixedLane(item.mode, nowMs);
        _fixeds.add(_ActiveFixed(item, lane, w, startMs: nowMs));
        final double x = _centerX(w);
        out.add(DanmakuRenderState(
          item: item,
          lane: lane,
          x: x,
          y: item.mode == DanmakuMode.bottom
              ? viewportHeight - bottomMargin - laneHeight * (lane + 1)
              : topMargin + lane * laneHeight,
          width: w,
          isScroll: false,
        ));
      }
    }

    // 4. 以车道优先排序（稳定渲染顺序：先入先出）。
    out.sort((DanmakuRenderState a, DanmakuRenderState b) {
      final int c = a.lane.compareTo(b.lane);
      return c != 0 ? c : a.item.timeMs.compareTo(b.item.timeMs);
    });
    return out;
  }

  /// 清空内部状态（切视频 / 重播时调用）。
  void reset() {
    _scrolls.clear();
    _fixeds.clear();
  }

  final List<_ActiveScroll> _scrolls = <_ActiveScroll>[];
  final List<_ActiveFixed> _fixeds = <_ActiveFixed>[];

  double _centerX(double width) =>
      ((viewportWidth - width) / 2).clamp(0.0, math.max(0, viewportWidth - width));

  void _expire(int nowMs) {
    // 滚动弹幕过期判定在 compute 的推进循环中（出屏移除）。
    _fixeds.removeWhere(
      (_ActiveFixed f) => nowMs - f.startMs >= topBottomLifetimeMs,
    );
  }

  /// 选择滚动车道：避免与已入场弹幕重叠（首尾间距 ≥ [minScrollGapPx]）。
  int _pickScrollLane(double width, int nowMs) {
    final double speed = effectiveScrollSpeed;
    for (int lane = 0; lane < scrollLaneCount; lane++) {
      bool busy = false;
      for (final _ActiveScroll a in _scrolls) {
        if (a.lane != lane) continue;
        // 新弹幕右缘贴边入场，需与同车道已有弹幕保持间距。
        final double aRight = a.startX -
            (nowMs - a.startMs) / 1000 * speed +
            a.width;
        if (aRight > viewportWidth - width - minScrollGapPx &&
            aRight <= viewportWidth + a.width) {
          busy = true;
          break;
        }
      }
      if (!busy) return lane;
    }
    return nowMs ~/ 1000 % scrollLaneCount; // 兜底：轮转车道
  }

  /// 选择顶/底固定车道：同车道同模式无存活弹幕。
  int _pickFixedLane(DanmakuMode mode, int nowMs) {
    final int count = math.max(1, scrollLaneCount);
    for (int lane = 0; lane < count; lane++) {
      final bool busy = _fixeds.any(
        (_ActiveFixed f) => f.lane == lane && f.item.mode == mode,
      );
      if (!busy) return lane;
    }
    return nowMs ~/ 1000 % count;
  }
}

class _ActiveScroll {
  _ActiveScroll(
    this.item,
    this.lane,
    this.width, {
    required this.startMs,
    required this.startX,
  });

  final DanmakuItem item;
  final int lane;
  final double width;
  final int startMs;

  /// 入场横坐标（滚动弹幕自右边缘 `viewportWidth` 入场）。
  final double startX;
}

class _ActiveFixed {
  _ActiveFixed(this.item, this.lane, this.width, {required this.startMs});

  final DanmakuItem item;
  final int lane;
  final double width;
  final int startMs;
}
