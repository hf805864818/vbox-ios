/// 平台层：屏幕常亮控制（UI-D2）。
///
/// 对齐 iOS `UIApplication.shared.isIdleTimerDisabled` 语义
/// （[MPVKitRenderedPlayerCore.swift](../../../../vbox/PlayerCore/MPVKitRenderedPlayerCore.swift#L60-L79)
/// 三内核 `play()` 开启 / `pause()`·`stop()` 恢复，
/// [PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L1712-L1716)
/// `updateIdleTimer()` 按 `isPlaying` 收口）：
///  - 按**播放状态**驱动而非页面生命周期：playing → 常亮，暂停 / 停止 / 结束 → 恢复；
///  - 暂停时显式恢复（iOS 注释：后台场景系统可能重置 idle timer）；
///  - 设置失败不影响播放（iOS idle timer 设置本身不致错，Flutter 端平台异常静默）。
library;

import 'package:wakelock_plus/wakelock_plus.dart';

/// 屏幕常亮控制器抽象（播放页按播放状态同步调用，测试可注入）。
abstract class WakeLockController {
  /// 开启常亮（对齐 iOS `isIdleTimerDisabled = true`，播放中）。
  Future<void> enable();

  /// 关闭常亮（对齐 iOS `isIdleTimerDisabled = false`，暂停 / 停止 / 退出）。
  Future<void> disable();
}

/// [WakeLockController] 的 wakelock_plus 实现。
///
/// 平台异常静默：wakelock 在部分宿主（测试 / 未注册通道）不可用时
/// 不应影响播放主链路，与 iOS「idle timer 设置永不致错」口径一致。
class WakelockPlusController implements WakeLockController {
  /// 构造（常量，播放页可直接默认持有）。
  const WakelockPlusController();

  @override
  Future<void> enable() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  @override
  Future<void> disable() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }
}
