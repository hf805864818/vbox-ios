/// 自适应框架 · 响应式网格（批次 A · A-07）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.3（内容列数）：
///   竖屏 3 列 · 横屏 5–8 列。
///
/// 列数只依赖「形态 + 可用宽度」，是纯函数 [ResponsiveGrid.columnsFor]，
/// 便于单测穷举；渲染层用 [LayoutBuilder] 注入真实宽度，避免写死断点魔数。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/spacing.dart';
import '../../ui_mode/ui_mode.dart';

/// 响应式网格（同一份子项，按形态产出不同列数）。
class ResponsiveGrid extends StatelessWidget {
  /// 构造。
  const ResponsiveGrid({
    super.key,
    required this.form,
    required this.children,
    this.spacing = VboxSpacing.md,
    this.columns,
    this.childAspectRatio = 0.7,
    this.padding = EdgeInsets.zero,
  });

  /// 当前形态。
  final UiForm form;

  /// 子项（顺序即排布顺序）。
  final List<Widget> children;

  /// 行/列间距（取自间距令牌）。
  final double spacing;

  /// 显式列数（非 null 时覆盖宽度推导；供页面按业务指定）。
  final int? columns;

  /// 单元宽高比。
  final double childAspectRatio;

  /// 网格内边距。
  final EdgeInsets padding;

  /// 横屏列数档位（升序断点 → 列数）。
  static const double landscapeBreakpoint6 = 960;
  static const double landscapeBreakpoint7 = 1200;
  static const double landscapeBreakpoint8 = 1600;

  /// 按形态 + 可用宽度推导列数（§3.3：竖屏 3，横屏 5–8）。
  static int columnsFor({required UiForm form, required double width}) {
    if (form.isPortrait) {
      return 3;
    }
    if (width >= landscapeBreakpoint8) return 8;
    if (width >= landscapeBreakpoint7) return 7;
    if (width >= landscapeBreakpoint6) return 6;
    return 5;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final int count = columns ?? columnsFor(form: form, width: width);
        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          crossAxisCount: count,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          childAspectRatio: childAspectRatio,
          children: children,
        );
      },
    );
  }
}