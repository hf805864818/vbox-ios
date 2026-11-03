/// 输入适配 · 焦点环（批次 A · A-09）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.4（遥控 D-pad：焦点遍历、
/// 可见焦点环，沿用 T.4/T.5）与 `docs/UI对齐基准_v1.0.md` #08（TV 焦点态：
/// **主色描边 + 放大 + 阴影**）。
///
/// 原则：**只加反馈层，不改版式** —— 放大用 `AnimatedScale`（变换，不占布局），
/// 描边画在子项边界内，不改变子项尺寸。
///
/// 门控：仅 `InputModality.remote`（遥控）下显示焦点环；触摸 / 鼠标键盘不显示
/// （四端同 UI，环是遥控专属反馈）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/tokens/radii.dart';
import '../../theme/tokens/shadows.dart';
import '../../ui_mode/ui_mode.dart';

/// 可见焦点环（包裹任意可聚焦子项）。
class FocusRing extends StatefulWidget {
  /// 构造。
  const FocusRing({
    super.key,
    required this.child,
    this.focusNode,
    this.radius,
    this.strokeWidth = 2.5,
    this.scaleOnFocus = 1.04,
  });

  /// 子项（自身可聚焦）。
  final Widget child;

  /// 外部焦点节点（缺省内部自建）。
  final FocusNode? focusNode;

  /// 环圆角（缺省取卡片档位）。
  final BorderRadius? radius;

  /// 环描边宽度。
  final double strokeWidth;

  /// 聚焦放大系数（TV 焦点态「放大」）。
  final double scaleOnFocus;

  /// 焦点环出现动画时长。
  static const Duration duration = Duration(milliseconds: 120);

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  late final FocusNode _node = widget.focusNode ?? FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
    _focused = _node.hasFocus;
  }

  void _sync() {
    if (!mounted) return;
    if (_node.hasFocus != _focused) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 遥控模态才显示焦点环（§3.4：D-pad 反馈层）。
    final bool remote = context.select<UiFormController, bool>(
      (UiFormController c) => c.modality == InputModality.remote,
    );
    final bool show = remote && _focused;

    return Focus(
      focusNode: _node,
      child: AnimatedScale(
        scale: show ? widget.scaleOnFocus : 1.0,
        duration: FocusRing.duration,
        curve: Curves.easeOut,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.radius ?? VboxRadii.card,
            border: Border.all(
              color: show ? scheme.primary : Colors.transparent,
              width: widget.strokeWidth,
            ),
            boxShadow: show ? VboxShadows.accent(scheme.primary) : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}