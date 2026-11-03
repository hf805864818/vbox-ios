/// 触感反馈统一收口（批次 E · E5-2）。
///
/// 对齐 iOS `UIImpactFeedbackGenerator` / `UISelectionFeedbackGenerator` 的
/// 三档语义，全端唯一入口；新增触感一律走本类，禁止直接调用
/// `HapticFeedback.*`（守卫口径见方案 E5-2）。
///
/// 落地差异（登记）：桌面端（Windows / macOS）无触感硬件，`HapticFeedback`
/// 调用为安全 no-op，无需平台分支。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 触感反馈收口。
abstract final class VboxHaptics {
  /// 轻触感（卡片点击 / 直播频道选择；对齐 iOS light impact）。
  static void light() => unawaited(HapticFeedback.lightImpact());

  /// 中触感（面板开合 / 长按 / 下载成败；对齐 iOS medium impact）。
  static void medium() => unawaited(HapticFeedback.mediumImpact());

  /// 选择触感（Tab 切换 / 选择器变更；对齐 iOS selection changed）。
  static void selection() => unawaited(HapticFeedback.selectionClick());
}
