/// 平台层：弹幕播放控制器（批次 C · C-03）。
///
/// 持有全量弹幕（按时间升序）与 [DanmakuLaneEngine]，按播放位置喂入
/// 「到期」弹幕并产出渲染状态。播放器页面每帧/定时调用 [tick]。
library;

import 'danmaku_item.dart';
import 'danmaku_lane_engine.dart';

/// 弹幕播放控制器（C-03）。
class DanmakuPlaybackController {
  /// 构造（[items] 复制并按 timeMs 升序；[engine] 可注入）。
  DanmakuPlaybackController({
    required List<DanmakuItem> items,
    DanmakuLaneEngine? engine,
  })  : _items = List<DanmakuItem>.of(items)
          ..sort((DanmakuItem a, DanmakuItem b) => a.timeMs.compareTo(b.timeMs)),
        _engine = engine ?? DanmakuLaneEngine();

  final List<DanmakuItem> _items;
  final DanmakuLaneEngine _engine;
  int _cursor = 0;

  /// 底层引擎（供渲染层取参数）。
  DanmakuLaneEngine get engine => _engine;

  /// 总弹幕数。
  int get totalCount => _items.length;

  /// 是否还有未出场的弹幕。
  bool get hasMore => _cursor < _items.length;

  /// 推进到 [nowMs]：喂入到期弹幕，返回当前应渲染的状态列表。
  List<DanmakuRenderState> tick(int nowMs) {
    final List<DanmakuItem> incoming = <DanmakuItem>[];
    while (_cursor < _items.length && _items[_cursor].timeMs <= nowMs) {
      incoming.add(_items[_cursor]);
      _cursor++;
    }
    return _engine.compute(nowMs, incoming);
  }

  /// 跳转到 [nowMs]（对齐 iOS 拖拽后重排）：光标二分定位到首条 ≥ 目标的弹幕，
  /// 清空在屏状态，避免回退跳转后漏发或重复发送。
  void seekTo(int nowMs) {
    _cursor = _lowerBound(nowMs);
    _engine.reset();
  }

  /// 本地立即插入一条弹幕（发送后先行显示，对齐 iOS 乐观更新）。
  void inject(DanmakuItem item) {
    final int i = _lowerBound(item.timeMs);
    _items.insert(i, item);
    if (i < _cursor) _cursor = i; // 使下次 tick 立即喂入新弹幕
  }

  /// 重置（切换视频 / 重播）。
  void reset() {
    _cursor = 0;
    _engine.reset();
  }

  /// 二分：首个 `timeMs >= target` 的下标。
  int _lowerBound(int targetMs) {
    int lo = 0;
    int hi = _items.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (_items[mid].timeMs < targetMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
