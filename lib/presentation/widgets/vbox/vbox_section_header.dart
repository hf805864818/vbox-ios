/// 统一组件库 · 区块标题（批次 A · A-04）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.3（16 · 区块标题 semibold）。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 区块标题（左标题 + 右侧可选操作）。
class VboxSectionHeader extends StatelessWidget {
  /// 构造。
  const VboxSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onSeeAll,
    this.seeAllLabel = '查看全部',
  });

  /// 标题。
  final String title;

  /// 副标题（可选，次级色）。
  final String? subtitle;

  /// 右侧自定义组件（优先级高于 [onSeeAll]）。
  final Widget? trailing;

  /// 「查看全部」回调。
  final VoidCallback? onSeeAll;

  /// 「查看全部」文案。
  final String seeAllLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget? end = trailing ??
        (onSeeAll == null
            ? null
            : TextButton(
                onPressed: onSeeAll,
                child: Text(
                  seeAllLabel,
                  style: TextStyle(
                    fontSize: VboxTypography.s13,
                    color: scheme.primary,
                  ),
                ),
              ));

    return Padding(
      padding: VboxSpacing.symmetric(vertical: VboxSpacing.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: VboxTypography.s16,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: VboxSpacing.symmetric(vertical: VboxSpacing.xs),
                    child: Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: VboxTypography.s12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (end != null) end,
        ],
      ),
    );
  }
}