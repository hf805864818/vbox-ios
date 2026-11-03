/// 豆瓣首页快捷分类胶囊行（UI-A1）。
///
/// 对齐 iOS `CategoryTilesView`（[DoubanHomeView.swift](../../../../../vbox/Views/DoubanHomeView.swift#L378-L418)）：
///  - 6 个固定胶囊（电影 / 剧集 / 综艺 / 榜单 / 动漫 / 热门），横向滚动，顺序一致；
///  - 位置在 banner 之后、内容区块之前；
///  - 选中态（详情弹层打开期间）填充 `#34C759` 白字 + 70% 同色描边，
///    弹层关闭后由父级清空 [activeType]（对齐 iOS `onDismiss` 清 `activeType`）。
///  - 单个胶囊样式对齐 iOS `CategoryTile`（L421-L457）：emoji 14pt + 标题
///    14pt medium，横 14 / 竖 8 内边距，胶囊形。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/douban/douban_models.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 首页快捷分类胶囊行。
class DoubanQuickCategories extends StatelessWidget {
  /// 构造。
  const DoubanQuickCategories({
    super.key,
    this.activeType,
    required this.onTileTap,
  });

  /// 当前高亮的分类 type（null 表示无高亮；对齐 iOS `activeType`）。
  final String? activeType;

  /// 胶囊点击回调。
  final ValueChanged<DoubanQuickTile> onTileTap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < DoubanCategory.quickTiles.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: VboxSpacing.sm),
            _QuickTile(
              tile: DoubanCategory.quickTiles[i],
              selected:
                  activeType == DoubanCategory.quickTiles[i].category.type,
              onTap: () => onTileTap(DoubanCategory.quickTiles[i]),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单个快捷分类胶囊（对齐 iOS `CategoryTile`）。
class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.tile,
    required this.selected,
    required this.onTap,
  });

  final DoubanQuickTile tile;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 选中填充 #34C759（对齐 iOS `Color(hex: "34C759")`）+ 白字；
    // 未选中：浅底 + 细描边（对齐 iOS tileBackground / borderColor）。
    final Color fill =
        selected ? VboxColors.chipSelected : scheme.surfaceContainerHighest;
    final Color stroke = selected
        ? VboxColors.chipSelected.withValues(alpha: 0.70)
        : scheme.outlineVariant;
    final Color foreground = selected ? Colors.white : scheme.onSurface;

    return Semantics(
      button: true,
      label: '快捷分类：${tile.name}',
      child: Material(
        color: fill,
        shape: StadiumBorder(side: BorderSide(color: stroke)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VboxSpacing.inputHorizontal,
              vertical: VboxSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  tile.emoji,
                  style: const TextStyle(fontSize: VboxTypography.s14),
                ),
                const SizedBox(width: VboxSpacing.compact),
                Text(
                  tile.name,
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    fontWeight: FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
