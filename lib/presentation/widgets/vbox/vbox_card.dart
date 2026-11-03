/// 统一组件库 · 卡片（批次 A · A-04）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.5（大卡片 / 面板）。
/// 规格：圆角 20（continuous 近似）+ 1px 线性渐变描边
/// （`systemBackground` 10% → 0%，左上 → 右下）。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/radii.dart';
import '../../theme/tokens/shadows.dart';
import '../../theme/tokens/spacing.dart';

/// 面板卡片（gradient-stroke card）。
class VboxCard extends StatelessWidget {
  /// 构造。
  const VboxCard({
    super.key,
    required this.child,
    this.padding = VboxSpacing.page,
    this.onTap,
    this.shadowColor,
    this.radius = VboxRadii.r20,
    this.color,
  });

  /// 内容。
  final Widget child;

  /// 内边距（默认 16）。
  final EdgeInsetsGeometry padding;

  /// 点击回调（非 null 时启用波纹）。
  final VoidCallback? onTap;

  /// 主色阴影色；非 null 时叠加主色阴影（UI 基准 §2.5）。
  final Color? shadowColor;

  /// 圆角（令牌档位，默认 20）。
  final double radius;

  /// 卡片底色；默认取 `colorScheme.surface`（系统底）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius inner = BorderRadius.circular(radius - 1);

    Widget body = Padding(padding: padding, child: child);
    if (onTap != null) {
      body = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: inner,
          onTap: onTap,
          child: body,
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            scheme.surface.withValues(alpha: 0.10),
            scheme.surface.withValues(alpha: 0.0),
          ],
        ),
        boxShadow: shadowColor == null ? null : VboxShadows.accent(shadowColor!),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color ?? scheme.surface,
            borderRadius: inner,
          ),
          child: body,
        ),
      ),
    );
  }
}