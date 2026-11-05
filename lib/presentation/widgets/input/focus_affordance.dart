/// 输入适配：焦点可视反馈（批次 B 补充 · TV 遥控可用性）。
///
/// 详情页存在两类交互：
///   1. 本身可聚焦的 `InkWell` / `IconButton`（Flutter 自带焦点与 Enter 激活），
///      缺的只是**可见焦点态** → 原地补 `focusColor`（不改结构、保留涟漪与语义）；
///   2. 只有 `GestureDetector` 的点击区（返回热区 / 线路 chip / 演职 tab / 收藏 /
///      网盘 tab），遥控根本到不了 → 用 [FocusableTap]：自带焦点 + 描边 +
///      `ActivateIntent`（OK/Enter）触发，触摸仍走点击。
///
/// 焦点环画在 `foregroundDecoration`（覆盖在子项之上，不参与布局），因此不会
/// 撑开任何尺寸；无 `onTap` 时不参与焦点。
library;

import 'package:flutter/material.dart';

/// 可聚焦点击区（遥控 / 键盘可到达；触摸仍可点击）。
class FocusableTap extends StatefulWidget {
  /// 构造。
  const FocusableTap({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius,
    this.semanticLabel,
    this.semanticSelected,
    this.autofocus = false,
  });

  /// 子项。
  final Widget child;

  /// 点击 / OK / Enter 触发；为 null 时不可交互、不参与焦点。
  final VoidCallback? onTap;

  /// 描边圆角。
  final BorderRadius? borderRadius;

  /// 无障碍标签（如「剧照 1」「收藏」）；null 时沿用子项文本。
  final String? semanticLabel;

  /// 无障碍选中态。
  final bool? semanticSelected;

  /// 是否自动获取焦点（弹窗内首个可聚焦项可用）。
  final bool autofocus;

  @override
  State<FocusableTap> createState() => _FocusableTapState();
}

class _FocusableTapState extends State<FocusableTap> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (_focused == focused) return;
    setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      selected: widget.semanticSelected,
      child: FocusableActionDetector(
        autofocus: widget.autofocus,
        enabled: enabled,
        onShowFocusHighlight: _onFocusChange,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            foregroundDecoration: _focused && enabled
                ? BoxDecoration(
                    borderRadius: widget.borderRadius,
                    border: Border.all(color: Colors.white, width: 2.5),
                  )
                : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
