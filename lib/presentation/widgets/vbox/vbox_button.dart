/// 统一组件库 · 按钮（批次 A · A-04）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.4（圆角 6–8）/ §2.5（危险操作）。
/// 规格：危险操作 = 文字红 + 背景红 @10% + 圆角 8。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 按钮形态。
enum VboxButtonKind {
  /// 主按钮（主色实心）。
  primary,

  /// 次按钮（描边）。
  secondary,

  /// 危险操作（红字 + 红底 @10%）。
  danger,
}

/// 统一按钮。
class VboxButton extends StatelessWidget {
  /// 构造。
  const VboxButton({
    super.key,
    required this.label,
    this.onPressed,
    this.kind = VboxButtonKind.primary,
    this.icon,
    this.expanded = false,
  });

  /// 文案。
  final String label;

  /// 点击回调（null = 禁用）。
  final VoidCallback? onPressed;

  /// 形态。
  final VboxButtonKind kind;

  /// 前置图标。
  final IconData? icon;

  /// 是否撑满父宽。
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    late final Color background;
    late final Color foreground;
    late final BorderSide side;
    switch (kind) {
      case VboxButtonKind.primary:
        background = scheme.primary;
        foreground = scheme.onPrimary;
        side = BorderSide.none;
      case VboxButtonKind.secondary:
        background = Colors.transparent;
        foreground = scheme.primary;
        side = BorderSide(color: scheme.outlineVariant);
      case VboxButtonKind.danger:
        background = VboxColors.danger.withValues(alpha: 0.10);
        foreground = VboxColors.danger;
        side = BorderSide.none;
    }

    final bool disabled = onPressed == null;
    Widget body = Row(
      mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: VboxTypography.s16, color: foreground),
          const SizedBox(width: VboxSpacing.sm),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: VboxTypography.s14,
            fontWeight: FontWeight.w600,
            color: foreground,
          ),
        ),
      ],
    );

    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(borderRadius: VboxRadii.button, side: side),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: VboxSpacing.symmetric(
              horizontal: VboxSpacing.xl,
              vertical: VboxSpacing.md,
            ),
            child: body,
          ),
        ),
      ),
    );
  }
}