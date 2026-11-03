/// 平台层：连播控制器（批次 C · C-05 自动连播下一集）。
///
/// 监听播放器状态事件：`ended` 且连播开启时触发 [onAdvance]（由 UI 层接线下
/// 一集；无下一集时 no-op）。纯逻辑、可注入，便于单测。
library;

import '../../domain/entities/player/player.dart';

/// 自动连播控制。
class AutoPlayNextController {
  /// 构造。
  AutoPlayNextController({
    required this.enabled,
    this.onAdvance,
  });

  /// 连播开关（来自 [PlaybackSettings.autoPlayNext]）。
  bool enabled;

  /// 推进到下一集回调（无下一集时由调用方 no-op）。
  void Function()? onAdvance;

  /// 处理一次播放器状态事件。
  void handleState(PlayerState state) {
    if (enabled && state == PlayerState.ended) {
      onAdvance?.call();
    }
  }
}
