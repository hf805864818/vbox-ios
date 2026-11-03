/// 统一组件库 · 导航（批次 A · A-04 / A8）。
///
/// 唯一真相源：iOS `ContentView.swift` L17-L56（Tab 组成与 `visibleTabs`）·
/// L108-L131（胶囊宽度公式与描边）· L256-L278（四皮肤底栏配色）。
///
/// 视觉语言（色 / 字号）对齐 UI 基准 §2；**全端（Android / Android TV /
/// Windows / macOS）统一底部悬浮胶囊 TabBar**（决策 2026-10-03，R-9），
/// 不再使用左侧 Rail 作为壳层导航。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/typography.dart';
import '../../theme/vbox_haptics.dart';

/// 导航项（共享模型，供底栏复用）。
class VboxNavItem {
  /// 构造。
  const VboxNavItem({
    required this.icon,
    required this.label,
    this.selectedIcon,
  });

  /// 默认图标。
  final IconData icon;

  /// 选中图标（缺省回退 [icon]）。
  final IconData? selectedIcon;

  /// 文案。
  final String label;
}

/// 底部悬浮胶囊 TabBar（全端统一形态，对齐 iOS `ContentView` 底栏）。
///
/// 规格（R-12）：
///   · 宽度 = `min(屏宽 − 140, Tab数 × 56 + 28)`；
///   · 每 Tab 宽 56；胶囊左右内边距 14、上下 5；
///   · 形状 `Capsule` + **1px 描边**；
///   · 文字 **10pt**（选中 semibold / 未选中 regular），图标 18。
class VboxBottomNav extends StatelessWidget {
  /// 构造。
  const VboxBottomNav({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.palette,
  });

  /// 导航项。
  final List<VboxNavItem> items;

  /// 当前索引。
  final int selectedIndex;

  /// 选择回调。
  final ValueChanged<int> onSelected;

  /// 四皮肤配色；缺省按浅色皮肤 + 当前亮度解析。
  final VboxTabBarPalette? palette;

  /// 每 Tab 宽度（iOS 固定 56）。
  static const double tabWidth = 56;

  /// 胶囊左右内边距。
  static const double horizontalPadding = 14;

  /// 胶囊上下内边距。
  static const double verticalPadding = 5;

  /// 屏宽扣减量（iOS `UIScreen.width - 140`）。
  static const double screenInset = 140;

  /// 底栏与屏幕底边留白。
  static const double bottomGap = 8;

  /// 胶囊宽度公式（R-12）。
  static double widthFor(double screenWidth, int tabCount) {
    final double byGrid = tabCount * tabWidth + horizontalPadding * 2;
    final double maxWidth = screenWidth - screenInset;
    return byGrid < maxWidth ? byGrid : maxWidth;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VboxTabBarPalette colors =
        palette ?? VboxTabBarPalette.resolve(VboxSkin.light, theme.brightness);
    final double screenWidth = MediaQuery.sizeOf(context).width;

    return Padding(
      padding: const EdgeInsets.only(bottom: bottomGap),
      child: Center(
        child: SizedBox(
          width: widthFor(screenWidth, items.length),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: colors.base,
              shape: StadiumBorder(
                side: BorderSide(color: colors.stroke, width: 1),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              child: Row(
                children: <Widget>[
                  for (int i = 0; i < items.length; i++)
                    Expanded(child: _tab(context, i, colors)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, int index, VboxTabBarPalette colors) {
    final bool selected = index == selectedIndex;
    final VboxNavItem item = items[index];
    final Color color = selected ? colors.active : colors.inactive;

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // E5-2 触感补点：Tab 切换 selection（对齐 iOS 底栏 tab 切换）。
        onTap: () {
          VboxHaptics.selection();
          onSelected(index);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                selected ? (item.selectedIcon ?? item.icon) : item.icon,
                size: VboxTypography.s18,
                color: color,
              ),
              const SizedBox(height: 1),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 侧边导航（组件库陈列用；**壳层已全端统一为底栏**，见 R-9）。
class VboxNavRail extends StatelessWidget {
  /// 构造。
  const VboxNavRail({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.extended = false,
    this.labelType = NavigationRailLabelType.all,
    this.leading,
    this.trailing,
  });

  /// 导航项。
  final List<VboxNavItem> items;

  /// 当前索引。
  final int selectedIndex;

  /// 选择回调。
  final ValueChanged<int> onSelected;

  /// 是否展开（显示文字）。
  final bool extended;

  /// 标签展示方式（[extended] 为真时忽略）。
  final NavigationRailLabelType? labelType;

  /// 顶部组件。
  final Widget? leading;

  /// 底部组件。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return NavigationRailTheme(
      data: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.12),
        selectedLabelTextStyle: TextStyle(
          fontSize: VboxTypography.s12,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: VboxTypography.s12,
          color: scheme.onSurfaceVariant,
        ),
      ),
      child: NavigationRail(
        selectedIndex: selectedIndex,
        onDestinationSelected: onSelected,
        extended: extended,
        labelType: extended ? null : labelType,
        groupAlignment: -0.9,
        leading: leading,
        trailing: trailing,
        destinations: <NavigationRailDestination>[
          for (final VboxNavItem item in items)
            NavigationRailDestination(
              icon: Icon(item.icon),
              selectedIcon: Icon(item.selectedIcon ?? item.icon),
              label: Text(item.label),
            ),
        ],
      ),
    );
  }
}
