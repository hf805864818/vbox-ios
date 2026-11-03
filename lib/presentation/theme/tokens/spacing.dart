/// 设计令牌 · 间距（批次 A · A-02）。
///
/// 基准采用 4 的倍数栅格（UI 基准 §2 未单列间距，此处按 4pt 栅格归纳）。
/// 呈现代码的间距值应取自本层，避免散落魔数。
library;

import 'package:flutter/widgets.dart';

/// 间距令牌。
class VboxSpacing {
  const VboxSpacing._();

  /// 0 · 无间距。
  static const double none = 0;

  /// 4 · 紧凑（图标与文字之间）。
  static const double xs = 4;

  /// 8 · 小间距（列表项内）。
  static const double sm = 8;

  /// 12 · 中小间距。
  static const double md = 12;

  /// 16 · 标准间距（页面内边距）。
  static const double lg = 16;

  /// 20 · 中大间距。
  static const double xl = 20;

  /// 24 · 大间距（区块之间）。
  static const double xxl = 24;

  /// 32 · 超大间距（页面分节）。
  static const double xxxl = 32;

  // ── 语义间距（批次 B · B3/B4，对齐 iOS 实测值，不在 4pt 栅格档位）──
  /// 14 · 设置行垂直内边距（iOS `SettingsToggleRow` / `SettingsNavigationRow` 的 v14）。
  static const double rowVertical = 14;

  /// 6 · 紧凑间距（皮肤卡网格间距与卡内水平内边距，iOS `skinSettingsSection` 的 6）。
  static const double compact = 6;

  /// 10 · 分段控件垂直内边距（iOS `RemoteWelfareHomeView` 分段 v10）。
  static const double segmentVertical = 10;

  /// 14 · 输入行水平内边距（iOS `LoginSheetView` 输入框 h14）。
  static const double inputHorizontal = 14;

  /// 全部间距档位（升序；单测断言用）。
  static const List<double> scale = <double>[
    none,
    xs,
    sm,
    md,
    lg,
    xl,
    xxl,
    xxxl,
  ];

  /// 四边等距。
  static EdgeInsets all(double value) => EdgeInsets.all(value);

  /// 水平 + 垂直分别等距。
  static EdgeInsets symmetric({double horizontal = none, double vertical = none}) =>
      EdgeInsets.symmetric(horizontal: horizontal, vertical: vertical);

  /// 页面通用内边距（16）。
  static const EdgeInsets page = EdgeInsets.all(lg);
}