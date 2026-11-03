/// 平台层：长按倍速（批次 C · C-05）。
///
/// 对齐 iOS 播放器「长按倍速」手势语义：按住 → 倍速切到契约键
/// `player_long_press_speed`（默认 2.0）；松开 → 恢复按下前的倍速。
///
/// 纯逻辑、可注入（`currentSpeed` 读取 + `setSpeed` 下发），便于单测。
library;

/// 长按倍速控制器。
class LongPressSpeedController {
  /// 构造。
  ///
  /// [longPressSpeed] 为长按目标倍速（契约 `player_long_press_speed`，
  /// ≤1.0 视为未启用——1x 长按无意义）；[currentSpeed] 读取当前倍速；
  /// [setSpeed] 下发倍速（接 [PlayerController.setSpeed]）。
  LongPressSpeedController({
    required double longPressSpeed,
    required double Function() currentSpeed,
    required Future<void> Function(double speed) setSpeed,
  })  : _longPressSpeed = longPressSpeed,
        _currentSpeed = currentSpeed,
        _setSpeed = setSpeed;

  double _longPressSpeed;
  final double Function() _currentSpeed;
  final Future<void> Function(double speed) _setSpeed;

  bool _active = false;
  double? _restoreSpeed;

  /// 运行时更新长按目标倍速（UI-F6 长按倍速设置面板 / 契约键回填）。
  ///
  /// 激活中改档位不改变本次长按的恢复目标（松开仍回到按下前倍速）。
  void updateSpeed(double value) {
    _longPressSpeed = value;
  }

  /// 长按倍速是否启用（≤1.0 视为未启用）。
  bool get enabled => _longPressSpeed > 1.0;

  /// 是否处于长按倍速中。
  bool get isActive => _active;

  /// 长按目标倍速。
  double get longPressSpeed => _longPressSpeed;

  /// 长按开始：记录当前倍速并切到长按倍速。
  ///
  /// 重复调用幂等（已激活时 no-op）。
  Future<void> begin() async {
    if (!enabled || _active) return;
    _active = true;
    _restoreSpeed = _currentSpeed();
    await _setSpeed(_longPressSpeed);
  }

  /// 长按结束：恢复按下前的倍速。
  ///
  /// 未激活时 no-op（幂等）。
  Future<void> end() async {
    if (!_active) return;
    _active = false;
    final double? restore = _restoreSpeed;
    _restoreSpeed = null;
    await _setSpeed(restore ?? 1.0);
  }
}
