/// 统一组件库 · 功能宫格（批次 B · B2）。
///
/// 唯一真相源：iOS `ProfileView.swift` L488-L502（`featureButton`）与
/// L413-L485（`featureEntriesSection`）：每格「图标 24（主色）+ 标题 12
/// （深色正文）」，格高 80，无卡片边框，等分宽度。
///
/// 全部只消费令牌层（间距 / 字号 / 圆角），主色取自当前 `ColorScheme.primary`。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 宫格单项。
class VboxQuickGridItem {
  /// 构造。
  const VboxQuickGridItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// 图标。
  final IconData icon;

  /// 标题。
  final String label;

  /// 点击回调。
  final VoidCallback onTap;
}

/// 功能宫格（默认 3 列，按行优先排列）。
class VboxQuickGrid extends StatelessWidget {
  /// 构造。
  const VboxQuickGrid({
    super.key,
    required this.items,
    this.crossAxisCount = 3,
  });

  /// 宫格项。
  final List<VboxQuickGridItem> items;

  /// 列数。
  final int crossAxisCount;

  /// 每格固定高度（对齐 iOS `featureButton` 的 `.frame(height: 80)`）。
  static const double itemHeight = 80;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: items.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisExtent: itemHeight,
      ),
      itemBuilder: (BuildContext context, int index) {
        final VboxQuickGridItem item = items[index];
        return InkWell(
          onTap: item.onTap,
          borderRadius: VboxRadii.button,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(item.icon, size: VboxTypography.s24, color: scheme.primary),
              const SizedBox(height: VboxSpacing.sm),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}