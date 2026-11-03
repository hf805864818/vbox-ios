/// 设计令牌 · 阴影（批次 A · A-02）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.5（阴影：主色 `opacity 0.35–0.40`、
/// `radius 10–16`、`y 4–6`）。
library;

import 'package:flutter/widgets.dart';

/// 阴影取值（UI 基准 §2.5）。
class VboxShadowSpec {
  const VboxShadowSpec._();

  /// 主色阴影不透明度下限。
  static const double opacityLow = 0.35;

  /// 主色阴影不透明度上限。
  static const double opacityHigh = 0.40;

  /// 模糊半径下限。
  static const double blurLow = 10;

  /// 模糊半径上限。
  static const double blurHigh = 16;

  /// 纵向偏移下限。
  static const double offsetYLow = 4;

  /// 纵向偏移上限。
  static const double offsetYHigh = 6;
}

/// 阴影令牌。
class VboxShadows {
  const VboxShadows._();

  /// 常规主色阴影（opacity 0.35 / blur 10 / y 4）。
  static List<BoxShadow> accent(Color color) => <BoxShadow>[
        BoxShadow(
          color: color.withValues(alpha: VboxShadowSpec.opacityLow),
          blurRadius: VboxShadowSpec.blurLow,
          offset: const Offset(0, VboxShadowSpec.offsetYLow),
        ),
      ];

  /// 重主色阴影（opacity 0.40 / blur 16 / y 6）。
  static List<BoxShadow> accentStrong(Color color) => <BoxShadow>[
        BoxShadow(
          color: color.withValues(alpha: VboxShadowSpec.opacityHigh),
          blurRadius: VboxShadowSpec.blurHigh,
          offset: const Offset(0, VboxShadowSpec.offsetYHigh),
        ),
      ];
}