/// 自适应框架 · 内容分栏（批次 A · A-07）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.3（详情页）：
///   竖屏 → 全屏页（列表即全屏）；横屏 → 列表 + 右侧详情面板。
///
/// 只做**排布**，不持有业务状态：详情是否展示由调用方决定（横屏可常驻面板，
/// 竖屏则经路由推入详情页）。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/spacing.dart';
import '../../ui_mode/ui_mode.dart';

/// 内容分栏：横屏时列表与详情并排，竖屏时仅列表全屏。
class ContentPanel extends StatelessWidget {
  /// 构造。
  const ContentPanel({
    super.key,
    required this.form,
    required this.list,
    this.detail,
    this.detailWidth = 420,
    this.showDetail,
    this.divider = true,
  });

  /// 当前形态。
  final UiForm form;

  /// 主列表区（始终展示）。
  final Widget list;

  /// 详情面板（横屏且 [showDetail] 为真时展示）。
  final Widget? detail;

  /// 详情面板宽度（横屏）。
  final double detailWidth;

  /// 是否展示详情（null → 等价于 [detail] != null）。
  final bool? showDetail;

  /// 是否在两栏间画分隔线。
  final bool divider;

  /// 竖屏是否内联详情：竖屏恒为 false（详情走全屏页路由）。
  bool get _inlineDetail =>
      form.isLandscape && detail != null && (showDetail ?? true);

  @override
  Widget build(BuildContext context) {
    if (!_inlineDetail) return list;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: list),
        if (divider)
          const VerticalDivider(width: VboxSpacing.sm, thickness: 0.5),
        SizedBox(width: detailWidth, child: detail),
      ],
    );
  }
}