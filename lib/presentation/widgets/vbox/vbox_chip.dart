/// 统一组件库 · 胶囊（批次 A · A-04）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.5（选中胶囊）。
/// 规格：选中 → 填充 `#34C759` + 同色描边 70%；未选中 → 分组底 + 描边。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 胶囊标签（分类 / 榜单 / 筛选）。
class VboxChip extends StatelessWidget {
  /// 构造。
  const VboxChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
    this.emoji,
    this.selectedColor = VboxColors.chipSelected,
    this.dense = false,
  });

  /// 文案。
  final String label;

  /// 是否选中。
  final bool selected;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 前置图标。
  final IconData? icon;

  /// 前置 emoji（对齐 iOS `CategoryTile` 的 emoji + 标题结构；与 [icon] 互斥，emoji 优先）。
  final String? emoji;

  /// 选中填充色（默认对齐 UI 基准的 `#34C759`）。
  final Color selectedColor;

  /// 紧凑模式（减小内边距）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color foreground = selected ? Colors.white : scheme.onSurfaceVariant;
    final Color background =
        selected ? selectedColor : scheme.surfaceContainerHighest;
    final Color stroke =
        selected ? selectedColor.withValues(alpha: 0.70) : scheme.outlineVariant;

    final EdgeInsetsGeometry pad = dense
        ? VboxSpacing.symmetric(horizontal: VboxSpacing.md, vertical: VboxSpacing.xs)
        : VboxSpacing.symmetric(horizontal: VboxSpacing.lg, vertical: VboxSpacing.sm);

    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: VboxRadii.chip,
        side: BorderSide(color: stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: pad,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (emoji != null) ...<Widget>[
                // emoji 走文本渲染（14pt，对齐 iOS CategoryTile 14pt emoji）。
                Text(
                  emoji!,
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    color: foreground,
                  ),
                ),
                const SizedBox(width: VboxSpacing.compact),
              ] else if (icon != null) ...<Widget>[
                Icon(icon, size: VboxTypography.s14, color: foreground),
                const SizedBox(width: VboxSpacing.xs),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: VboxTypography.s13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}