/// 输入适配 · 十英尺缩放（批次 A · A-09）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.3（TV 叠加 1.2–1.5×
/// 十英尺缩放）与 §3.6（TV 缩放不计入保真度指标）。
///
/// 机制：遥控模态下把 `MediaQuery.textScaler` 按档位放大（默认 1.35×），
/// 文案随 `TextTheme` 档位等比放大；**不动版式结构**（尺寸/间距不变，
/// 由页面按需结合大屏约束排版）。触摸 / 鼠标键盘不缩放。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ui_mode/ui_mode.dart';

/// 十英尺缩放层（包裹子树）。
class TenFootScaler extends StatelessWidget {
  /// 构造。
  const TenFootScaler({
    super.key,
    required this.child,
    this.scale = defaultScale,
  });

  /// 子项。
  final Widget child;

  /// 缩放档位（§3.3：1.2–1.5×）。
  final double scale;

  /// 最小档位。
  static const double minScale = 1.2;

  /// 最大档位。
  static const double maxScale = 1.5;

  /// 默认档位（TV 基准）。
  static const double defaultScale = 1.35;

  /// 按输入模态取缩放（遥控 → [scale]，其余 → 1.0）。
  double _scaleFor(InputModality modality) =>
      modality == InputModality.remote ? scale : 1.0;

  @override
  Widget build(BuildContext context) {
    final InputModality modality = context.select<UiFormController, InputModality>(
      (UiFormController c) => c.modality,
    );
    final double factor = _scaleFor(modality);
    if (factor == 1.0) return child;

    final MediaQueryData mq = MediaQuery.of(context);
    final double base = mq.textScaler.scale(1.0);
    return MediaQuery(
      data: mq.copyWith(
        textScaler: TextScaler.linear(base * factor.clamp(minScale, maxScale)),
      ),
      child: child,
    );
  }
}