/// 输入适配 · 悬停反馈（批次 A · A-09）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.4（鼠标键盘：hover 态）。
///
/// 原则：**只加反馈层，不改版式** —— 仅主色 6% 的底色淡入，不改变尺寸/间距。
///
/// 门控：仅 `InputModality.mouseKeyboard` 下响应 hover；触摸 / 遥控不显示
/// （遥控走 [FocusRing] 焦点环）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ui_mode/ui_mode.dart';

/// 悬停反馈层（包裹任意子项）。
class HoverAffordance extends StatefulWidget {
  /// 构造。
  const HoverAffordance({
    super.key,
    required this.child,
    this.radius,
    this.onHoverChange,
  });

  /// 子项。
  final Widget child;

  /// 高亮圆角。
  final BorderRadius? radius;

  /// 悬停状态变化回调（外部联动，如光标样式）。
  final ValueChanged<bool>? onHoverChange;

  /// 悬停动画时长。
  static const Duration duration = Duration(milliseconds: 120);

  @override
  State<HoverAffordance> createState() => _HoverAffordanceState();
}

class _HoverAffordanceState extends State<HoverAffordance> {
  bool _hovered = false;

  void _set(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    widget.onHoverChange?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool mouse = context.select<UiFormController, bool>(
      (UiFormController c) => c.modality == InputModality.mouseKeyboard,
    );
    final bool show = mouse && _hovered;

    return MouseRegion(
      onEnter: mouse ? (_) => _set(true) : null,
      onExit: mouse ? (_) => _set(false) : null,
      child: AnimatedContainer(
        duration: HoverAffordance.duration,
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: show ? scheme.primary.withValues(alpha: 0.06) : Colors.transparent,
          borderRadius: widget.radius,
        ),
        child: widget.child,
      ),
    );
  }
}