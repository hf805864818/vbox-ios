/// 统一组件库 · 源标签（批次 A · A-04）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.2（分类色板 · 固定语义映射）
/// 与 §2.4（圆角 4 · 小标签 / 角标）。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 源 / 分类标签（小角标）。
class VboxSourceBadge extends StatelessWidget {
  /// 构造（按分类取固定语义色）。
  const VboxSourceBadge.category({
    super.key,
    required this.label,
    required VboxCategory category,
  }) : color = null,
       _category = category;

  /// 构造（自定义颜色）。
  const VboxSourceBadge({
    super.key,
    required this.label,
    required Color this.color,
  })  : _category = null;

  /// 文案。
  final String label;

  /// 自定义颜色（与 [_category] 二选一）。
  final Color? color;

  final VboxCategory? _category;

  /// 解析颜色：显式颜色优先，否则按分类色板固定映射（UI 基准 §2.2）。
  Color _resolve() => color ?? VboxColors.categoryColors[_category]!;

  @override
  Widget build(BuildContext context) {
    final Color accent = _resolve();
    return Container(
      padding: VboxSpacing.symmetric(
        horizontal: VboxSpacing.sm,
        vertical: VboxSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.15),
        borderRadius: VboxRadii.badge,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: VboxTypography.s10,
          fontWeight: FontWeight.w600,
          color: accent,
        ),
      ),
    );
  }
}