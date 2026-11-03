/// 统一组件库 · 设置页组件（批次 B · B3）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift`
///   · `SettingsSection`（L1330-L1342）—— 分组标题 + 圆角容器 + 1px 行间隙；
///   · `SettingsToggleRow`（L1520-L1536）—— 开关行；
///   · `SettingsNavigationRow`（L1538-L1559）—— 箭头行；
///   · 播放设置内的输入行（L199-L215）—— 图标 + 内嵌输入框。
///
/// 规格（照 iOS 实测）：
///   · 分组标题 13pt semibold · secondary；容器圆角 16；水平内边距 16；
///   · 行内边距 h16 / v14；行底 `secondarySystemGroupedBackground`；
///   · 行图标 18pt、占位宽 28；标题 15pt medium；副标题 13pt secondary。
///
/// Flutter 近似：iOS 的 `.thinMaterial` 毛玻璃无对应内建，改用行底 + 1px
/// [Divider]（`separator` 色、左缩 16）表达分组分隔 —— 必要的可见近似。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 设置分组（标题 + 圆角容器 + 行间 1px 分隔）。
class VboxSettingsSection extends StatelessWidget {
  /// 构造。
  const VboxSettingsSection({
    super.key,
    required this.title,
    required this.children,
  });

  /// 分组标题（13pt semibold · secondary）。
  final String title;

  /// 行内容（自动插入分隔线）。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final _SettingsPalette p = _SettingsPalette.of(context);
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i != children.length - 1) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: VboxSpacing.lg,
            color: p.separator,
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(
              left: VboxSpacing.xs,
              top: VboxSpacing.sm,
              bottom: VboxSpacing.sm,
            ),
            child: Text(
              title,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w600,
                color: p.secondaryLabel,
              ),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(VboxRadii.r16),
            child: Column(children: rows),
          ),
        ],
      ),
    );
  }
}

/// 设置行（图标 + 标题/副标题 + 尾部控件）。
///
/// 三种行型经命名构造表达：
///   · [VboxSettingsRow.toggle]     —— 尾部 `Switch.adaptive`（受 A4 `switchTheme` 配色）；
///   · [VboxSettingsRow.navigation] —— 尾部退出箭头，整行可点；
///   · [VboxSettingsInputRow]       —— 输入行（独立组件，TextField 占主体）。
class VboxSettingsRow extends StatelessWidget {
  /// 通用构造（自定义 [trailing]）。
  const VboxSettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.trailing,
    this.onTap,
  });

  /// 开关行工厂（对齐 iOS `SettingsToggleRow`）。
  ///
  /// 用静态工厂而非命名构造：`Switch` 需要运行时 `value`，构造器无法 `const`，
  /// 会触发 `prefer_const_constructors_in_immutables`；调用语法与构造器一致。
  static VboxSettingsRow toggle({
    Key? key,
    required String title,
    String? subtitle,
    IconData? icon,
    Color? iconColor,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      VboxSettingsRow(
        key: key,
        title: title,
        subtitle: subtitle,
        icon: icon,
        iconColor: iconColor,
        trailing: Switch.adaptive(value: value, onChanged: onChanged),
      );

  /// 箭头行工厂（对齐 iOS `SettingsNavigationRow`）。
  static VboxSettingsRow navigation({
    Key? key,
    required String title,
    String? subtitle,
    IconData? icon,
    Color? iconColor,
    required VoidCallback onTap,
  }) =>
      VboxSettingsRow(
        key: key,
        title: title,
        subtitle: subtitle,
        icon: icon,
        iconColor: iconColor,
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        onTap: onTap,
      );

  /// 主标题（15pt medium）。
  final String title;

  /// 副标题（13pt secondary）。
  final String? subtitle;

  /// 左侧图标（18pt，占位宽 28）。
  final IconData? icon;

  /// 左侧图标颜色（默认皮肤主色，对齐 iOS `SettingsNavigationRow` 的 `#E11D48`）。
  final Color? iconColor;

  /// 尾部控件（开关 / 箭头 / 自定义）。
  final Widget? trailing;

  /// 整行点击。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final _SettingsPalette p = _SettingsPalette.of(context);
    final Color titleColor = Theme.of(context).colorScheme.onSurface;

    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.rowVertical,
      ),
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            SizedBox(
              width: 28,
              child: Icon(
                icon,
                size: VboxTypography.s18,
                color: iconColor ?? VboxColors.skinPrimaryRose,
              ),
            ),
            const SizedBox(width: VboxSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: VboxTypography.s15,
                    fontWeight: FontWeight.w500,
                    color: titleColor,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: VboxSpacing.xs),
                    child: Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: VboxTypography.s13,
                        color: p.secondaryLabel,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: VboxSpacing.md),
            trailing!,
          ],
        ],
      ),
    );

    return Material(
      color: p.rowBackground,
      child: onTap == null
          ? content
          : InkWell(onTap: onTap, child: content),
    );
  }
}

/// 设置输入行（图标 + 内嵌输入框，对齐 iOS 播放设置内的输入行）。
class VboxSettingsInputRow extends StatelessWidget {
  /// 构造。
  const VboxSettingsInputRow({
    super.key,
    required this.controller,
    this.icon = Icons.link_rounded,
    this.hint,
    this.onChanged,
    this.keyboardType,
  });

  /// 输入控制器。
  final TextEditingController controller;

  /// 左侧图标（14pt · secondary）。
  final IconData icon;

  /// 占位文字。
  final String? hint;

  /// 输入回调。
  final ValueChanged<String>? onChanged;

  /// 键盘类型。
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final _SettingsPalette p = _SettingsPalette.of(context);

    return Material(
      color: p.rowBackground,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.lg,
          vertical: VboxSpacing.md,
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 28,
              child: Icon(
                icon,
                size: VboxTypography.s14,
                color: p.secondaryLabel,
              ),
            ),
            const SizedBox(width: VboxSpacing.md),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                keyboardType: keyboardType,
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: hint,
                  hintStyle: TextStyle(
                    fontSize: VboxTypography.s14,
                    color: p.hintLabel,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置页配色（行底 / 分隔线 / 次级文字），按当前配色模式解析。
class _SettingsPalette {
  const _SettingsPalette({
    required this.rowBackground,
    required this.separator,
    required this.secondaryLabel,
    required this.hintLabel,
  });

  /// 行底（`secondarySystemGroupedBackground` @70%，对齐 iOS `.opacity(0.7)`）。
  final Color rowBackground;

  /// 行间分隔线（`.separator`）。
  final Color separator;

  /// 次级文字（`.secondaryLabel`）。
  final Color secondaryLabel;

  /// 占位文字（`.secondaryLabel` @50%，对齐 iOS `.opacity(0.5)`）。
  final Color hintLabel;

  static _SettingsPalette of(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color secondary =
        isDark ? VboxColors.secondaryLabelDark : VboxColors.secondaryLabelLight;
    return _SettingsPalette(
      rowBackground: (isDark
              ? VboxColors.secondarySystemGroupedBackgroundDark
              : VboxColors.secondarySystemGroupedBackgroundLight)
          .withValues(alpha: 0.7),
      separator: isDark ? VboxColors.separatorDark : VboxColors.separatorLight,
      secondaryLabel: secondary,
      hintLabel: secondary.withValues(alpha: 0.5),
    );
  }
}