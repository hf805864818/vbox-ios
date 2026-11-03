/// 平台层：视频区手势状态机（第 3 批 · UI-F1）。
///
/// 对齐 iOS `GestureControlView`（[PlayerViewsV2_Extensions.swift](../../../../vbox/Views/PlayerViewsV2_Extensions.swift#L6-L113)）：
///  - 首次拖动按方向判定模式：**横滑 = seek（仅横屏）**，否则按触点所在半屏
///    分派 **左半屏纵滑 = 亮度** / **右半屏纵滑 = 音量**；
///  - seek 增量上限 `clamp(duration × 0.12, 60, 300)` 秒；
///  - 亮度 / 音量灵敏度 `clamp(viewportHeight / 700, 0.45, 0.9)`，上滑增大。
///
/// 纯逻辑、可注入（[ScreenControlsBridge] 下发亮度 / 音量），便于单测。
library;

import 'dart:ui' show Offset, Size;

import 'screen_controls.dart';

/// 手势模式（对齐 iOS `GestureMode`）。
enum GestureMode {
  /// 亮度调节（左半屏纵滑）。
  brightness,

  /// 音量调节（右半屏纵滑）。
  volume,

  /// 快进 / 快退（横滑，仅横屏）。
  seek,

  /// 忽略（未判定 / 竖屏横滑）。
  ignored,
}

/// 一次手势调节的结果（供 HUD 展示 + 落值）。
class GestureAdjustment {
  /// 构造。
  const GestureAdjustment({
    required this.mode,
    this.brightness = 0,
    this.volume = 0,
    this.seekSeconds = 0,
    this.label = '',
  });

  /// 当前模式。
  final GestureMode mode;

  /// 亮度（0.0 ~ 1.0；仅 [GestureMode.brightness] 有效）。
  final double brightness;

  /// 音量（0.0 ~ 1.0；仅 [GestureMode.volume] 有效）。
  final double volume;

  /// seek 目标秒数（仅 [GestureMode.seek] 有效）。
  final double seekSeconds;

  /// HUD 文案。
  final String label;
}

/// 视频区手势控制器。
class PlayerGestureController {
  /// 构造。
  PlayerGestureController({required ScreenControlsBridge screen})
      : _screen = screen;

  /// 拖动最小距离（对齐 iOS `DragGesture(minimumDistance: 14)`）。
  static const double minDistance = 14;

  /// 判定 seek 的最小横向位移（对齐 iOS 的 24）。
  static const double seekMinHorizontal = 24;

  /// 判定 seek 的横纵比阈值（对齐 iOS 的 1.15）。
  static const double seekHorizontalRatio = 1.15;

  /// seek 增量上限系数（对齐 iOS `duration * 0.12`）。
  static const double seekMaxDurationRatio = 0.12;

  /// seek 增量下限 / 上限（秒）。
  static const double seekMaxSecondsFloor = 60;
  static const double seekMaxSecondsCeil = 300;

  /// 灵敏度上下限 / 高度基准（对齐 iOS `min(max(h/700, 0.45), 0.9)`）。
  static const double sensitivityMin = 0.45;
  static const double sensitivityMax = 0.9;
  static const double sensitivityHeightBasis = 700;

  final ScreenControlsBridge _screen;

  /// 当前屏幕亮度（0.0 ~ 1.0）。
  double brightness = 0.5;

  /// 当前系统音量（0.0 ~ 1.0）。
  double volume = 0.5;

  GestureMode _mode = GestureMode.ignored;
  bool _active = false;
  double _startBrightness = 0.5;
  double _startVolume = 0.5;
  int _startPositionMs = 0;
  int _durationMs = 0;
  int _seekTargetMs = 0;
  Size _viewport = Size.zero;
  bool _landscape = false;

  /// 是否已判定模式。
  bool get isActive => _active;

  /// 当前模式。
  GestureMode get mode => _mode;

  /// 当前 seek 预览位置（毫秒；仅 seek 模式有效）。
  int get seekTargetMs => _seekTargetMs;

  /// 读取初值（进入播放页时调用一次；读取失败保持默认 0.5）。
  Future<void> load() async {
    brightness = await _screen.getBrightness();
    volume = await _screen.getVolume();
  }

  /// 手势开始：记录起点快照（模式延迟到首次 [update] 按位移判定）。
  ///
  /// [landscape] 决定是否允许横滑 seek（对齐 iOS 仅非竖屏可 seek）。
  void begin({
    required Offset localPosition,
    required Size viewport,
    required bool landscape,
    required int positionMs,
    required int durationMs,
  }) {
    _active = false;
    _mode = GestureMode.ignored;
    _startBrightness = brightness;
    _startVolume = volume;
    _startPositionMs = positionMs;
    _durationMs = durationMs;
    _seekTargetMs = positionMs;
    _viewport = viewport;
    _landscape = landscape;
    _startLocationX = localPosition.dx;
  }

  double _startLocationX = 0;

  /// 手势推进：返回本次调节结果（模式未判定或忽略时为 null）。
  ///
  /// [translation] 为相对起点的位移。
  Future<GestureAdjustment?> update(Offset translation) async {
    final double width = _viewport.width;
    final double height = _viewport.height;
    if (width <= 0 || height <= 0) return null;

    if (!_active) {
      if (translation.distance < minDistance) return null;
      _active = true;
      final double horizontal = translation.dx.abs();
      final double vertical = translation.dy.abs();
      if (_landscape &&
          horizontal > seekMinHorizontal &&
          horizontal > vertical * seekHorizontalRatio) {
        _mode = GestureMode.seek;
      } else if (_startLocationX < width / 2) {
        _mode = GestureMode.brightness;
      } else {
        _mode = GestureMode.volume;
      }
    }

    switch (_mode) {
      case GestureMode.seek:
        final double maxSeconds = _maxSeekSeconds();
        final double deltaSeconds = translation.dx / (width == 0 ? 1 : width) *
            maxSeconds;
        final double maxDurationSec = _durationMs / 1000.0;
        final double target =
            (_startPositionMs / 1000.0 + deltaSeconds).clamp(0, maxDurationSec);
        _seekTargetMs = (target * 1000).round();
        return GestureAdjustment(
          mode: GestureMode.seek,
          seekSeconds: target,
          label: '${_formatClock(_seekTargetMs)} / '
              '${_formatClock(_durationMs)}',
        );
      case GestureMode.brightness:
        final double delta = _verticalDelta(translation, height);
        brightness = clamp01(_startBrightness + delta);
        await _screen.setBrightness(brightness);
        return GestureAdjustment(
          mode: GestureMode.brightness,
          brightness: brightness,
          label: '亮度 ${(brightness * 100).round()}%',
        );
      case GestureMode.volume:
        final double delta = _verticalDelta(translation, height);
        volume = clamp01(_startVolume + delta);
        await _screen.setVolume(volume);
        return GestureAdjustment(
          mode: GestureMode.volume,
          volume: volume,
          label: '音量 ${(volume * 100).round()}%',
        );
      case GestureMode.ignored:
        return null;
    }
  }

  /// 手势结束：seek 模式返回目标位置（毫秒）；其余返回 null。
  int? end() {
    final bool wasSeek = _mode == GestureMode.seek;
    final int target = _seekTargetMs;
    _active = false;
    _mode = GestureMode.ignored;
    return wasSeek ? target : null;
  }

  /// 取消（不提交 seek）。
  void cancel() {
    _active = false;
    _mode = GestureMode.ignored;
  }

  /// seek 增量上限（秒；对齐 iOS `clamp(duration × 0.12, 60, 300)`）。
  double _maxSeekSeconds() {
    final double byDuration = _durationMs / 1000.0 * seekMaxDurationRatio;
    return byDuration.clamp(seekMaxSecondsFloor, seekMaxSecondsCeil);
  }

  /// 纵滑增量（对齐 iOS `-translation.height / height × sensitivity`）。
  double _verticalDelta(Offset translation, double height) {
    final double sensitivity = (height / sensitivityHeightBasis)
        .clamp(sensitivityMin, sensitivityMax);
    return -translation.dy / height * sensitivity;
  }

  /// 毫秒 → `mm:ss`（负值钳零）。
  static String _formatClock(int ms) {
    final int total = ms < 0 ? 0 : ms ~/ 1000;
    final int m = total ~/ 60;
    final int s = total % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
