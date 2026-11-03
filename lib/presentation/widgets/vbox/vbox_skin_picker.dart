/// 统一组件库 · 皮肤选择器（批次 B · B4）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift`
///   · `SkinModeButton`（L1344-L1416）—— 单个皮肤卡；
///   · `skinSettingsSection`（L136-L173）—— 2 列网格布局。
///
/// 规格（照 iOS 实测）：
///   · 2 列网格，行列间距 6；
///   · 卡片：图标 14pt / 标题 11pt semibold / 副标题 10pt，垂直排列间距 4；
///     圆角 10；内边距 v8 / h6；
///   · 选中：按皮肤填充渐变（见 [VboxColors.skinCardGradient]）+ 选中文字色 +
///     `systemBackground` 45% 描边；未选中：分组底渐变 + `separator` 35% 描边。
///
/// 近似说明：iOS 副标题为 9pt，Flutter 字号档位下限为 10（UI 守卫 R-3），
/// 取最近档位 10 —— 属「字号档位对齐」下的必要近似。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 皮肤选择器（2×2 四选，对齐 iOS `skinSettingsSection` 的 `LazyVGrid`）。
class VboxSkinPicker extends StatelessWidget {
  /// 构造。
  const VboxSkinPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.columns = 2,
  });

  /// 当前选中的皮肤。
  final VboxSkin selected;

  /// 选择回调（对齐 iOS `selectSkin`：选择即关闭「跟随系统」）。
  final ValueChanged<VboxSkin> onSelected;

  /// 列数（默认 2，对齐 iOS）。
  final int columns;

  @override
  Widget build(BuildContext context) {
    const List<VboxSkin> skins = VboxSkin.values;
    final List<Widget> rows = <Widget>[];

    for (int i = 0; i < skins.length; i += columns) {
      final List<Widget> cells = <Widget>[];
      for (int j = 0; j < columns; j++) {
        if (j > 0) cells.add(const SizedBox(width: VboxSpacing.compact));
        final int index = i + j;
        cells.add(
          Expanded(
            child: index < skins.length
                ? VboxSkinCard(
                    skin: skins[index],
                    isSelected: skins[index] == selected,
                    onTap: () => onSelected(skins[index]),
                  )
                : const SizedBox.shrink(),
          ),
        );
      }
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : VboxSpacing.compact),
          child: Row(children: cells),
        ),
      );
    }

    return Column(children: rows);
  }
}

/// 单个皮肤卡（对齐 iOS `SkinModeButton`）。
class VboxSkinCard extends StatelessWidget {
  /// 构造。
  const VboxSkinCard({
    super.key,
    required this.skin,
    required this.isSelected,
    this.onTap,
  });

  /// 目标皮肤。
  final VboxSkin skin;

  /// 是否选中。
  final bool isSelected;

  /// 点击回调。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    // iOS：light / frosted 选中时为深色文字，dark / liquid 为白色。
    final bool onLightCard = skin == VboxSkin.light || skin == VboxSkin.frosted;
    final Color selectedText = onLightCard
        ? VboxColors.skinCardOnLightText
        : VboxColors.systemBackgroundLight;

    final Color textColor =
        isSelected ? selectedText : Theme.of(context).colorScheme.onSurface;
    final Color subtitleColor = isSelected
        ? selectedText.withValues(alpha: onLightCard ? 0.72 : 0.82)
        : (isDark ? VboxColors.secondaryLabelDark : VboxColors.secondaryLabelLight);

    final Gradient fill = isSelected
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: VboxColors.skinCardGradient(skin),
          )
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              (isDark
                      ? VboxColors.secondarySystemGroupedBackgroundDark
                      : VboxColors.secondarySystemGroupedBackgroundLight)
                  .withValues(alpha: 0.95),
              (isDark
                      ? VboxColors.tertiarySystemGroupedBackgroundDark
                      : VboxColors.tertiarySystemGroupedBackgroundLight)
                  .withValues(alpha: 0.9),
            ],
          );

    final Color strokeBase =
        isDark ? VboxColors.separatorDark : VboxColors.separatorLight;
    final Color stroke = isSelected
        ? VboxColors.systemBackgroundLight.withValues(alpha: 0.45)
        : strokeBase.withValues(alpha: 0.35);

    return Semantics(
      selected: isSelected,
      button: true,
      label: skin.title,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(VboxRadii.r10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(VboxRadii.r10),
              gradient: fill,
              border: Border.all(color: stroke, width: 1),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: VboxSpacing.sm,
                horizontal: VboxSpacing.compact,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(_iconFor(skin), size: VboxTypography.s14, color: textColor),
                  const SizedBox(height: VboxSpacing.xs),
                  Text(
                    skin.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s11,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  Text(
                    _subtitleFor(skin),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s10,
                      color: subtitleColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 皮肤图标（对齐 iOS `AppSkinMode.icon` 的 SF Symbols）。
  IconData _iconFor(VboxSkin value) => switch (value) {
        VboxSkin.light => Icons.wb_sunny_rounded, // sun.max.fill
        VboxSkin.dark => Icons.dark_mode_rounded, // moon.fill
        VboxSkin.liquid => Icons.water_drop_rounded, // drop.fill
        VboxSkin.frosted => Icons.auto_awesome_rounded, // sparkles
      };

  /// 皮肤说明（对齐 iOS `AppSkinMode.subtitle`）。
  String _subtitleFor(VboxSkin value) => switch (value) {
        VboxSkin.light => '保持当前浅色风格',
        VboxSkin.dark => '全局深色界面',
        VboxSkin.liquid => '流动渐变与毛玻璃',
        VboxSkin.frosted => '全局磨砂玻璃质感',
      };
}