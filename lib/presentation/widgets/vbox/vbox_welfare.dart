/// 统一组件库 · 福利三栏目（批次 B · B6）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/RemoteWelfareHomeView.swift`
///   · 分段 Tab（L118-L154）与 `themeGradient`（L352-L370）；
///   · 平台网格 `RemotePlatformIconCard`（L395-L418）与 `platformGradient`（L373-L387）。
///
/// 规格（照 iOS 实测 / 图17）：
///   · 分段：三栏等宽，选中 = 圆角 12 **实心渐变**（直播为紫色）+ 白字，未选中 = 无色 + 主色 50%；
///     行内图标 14 + 文字 15（选中 bold / 未选中 regular），垂直内边距 10；
///   · 网格：4 列，列距 16；每格 = 52×52 圆角 16 渐变方块（白图标 24 + 同色 30% 阴影 6/3）
///     + 名称 12 medium（单行截断），格高 86。
///
/// 近似说明（平台图标配色）：iOS 以 `abs(name.hashValue) % 8` 取色，而 Swift
/// `String.hashValue` 每进程随机 —— 截图中的具体配色不可复现，Flutter 侧改用
/// [VboxColors.welfarePlatformGradient] 的稳定求和哈希；平台图标为远程动态数据，
/// 由调用方（H-06）注入，本组件只做布局与交互。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../theme/vbox_haptics.dart';

/// 福利栏目（对齐 iOS `RemoteWelfareCategory`）。
enum VboxWelfareCategory {
  /// 视频。
  video('视频', Icons.smart_display_rounded),

  /// 直播。
  live('直播', Icons.podcasts),

  /// 漫画。
  comic('漫画', Icons.menu_book_rounded);

  const VboxWelfareCategory(this.label, this.icon);

  /// 栏目名（「视频 / 直播 / 漫画」）。
  final String label;

  /// 栏目图标（Material 近似 SF Symbol）。
  final IconData icon;

  /// 选中态渐变（对齐 iOS `themeGradient`）。
  List<Color> get gradient => switch (this) {
        VboxWelfareCategory.video => VboxColors.welfareTabVideoGradient,
        VboxWelfareCategory.live => VboxColors.welfareTabLiveGradient,
        VboxWelfareCategory.comic => VboxColors.welfareTabComicGradient,
      };
}

/// 福利分段 Tab（对齐 iOS `RemoteWelfareHomeView` 顶部分段）。
class VboxWelfareTabs extends StatelessWidget {
  /// 构造。
  const VboxWelfareTabs({
    super.key,
    required this.selected,
    required this.onSelected,
    this.categories = VboxWelfareCategory.values,
  });

  /// 当前栏目。
  final VboxWelfareCategory selected;

  /// 切换回调。
  final ValueChanged<VboxWelfareCategory> onSelected;

  /// 栏目列表（默认三栏全量）。
  final List<VboxWelfareCategory> categories;

  @override
  Widget build(BuildContext context) {
    final Color inactive =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.only(
        left: VboxSpacing.lg,
        right: VboxSpacing.lg,
        top: VboxSpacing.md,
        bottom: VboxSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          for (final VboxWelfareCategory category in categories)
            Expanded(child: _tab(context, category, inactive)),
        ],
      ),
    );
  }

  Widget _tab(
      BuildContext context, VboxWelfareCategory category, Color inactive) {
    final bool on = category == selected;
    final Color textColor = on ? Colors.white : inactive;
    return Semantics(
      // UI-D4 辅助功能：福利分类标签。
      label: category.label,
      selected: on,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onSelected(category),
          borderRadius: BorderRadius.circular(VboxRadii.r12),
          child: Container(
            padding: const EdgeInsets.symmetric(
              vertical: VboxSpacing.segmentVertical,
            ),
            decoration: BoxDecoration(
              gradient: on
                  ? LinearGradient(
                      colors: category.gradient,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              borderRadius: BorderRadius.circular(VboxRadii.r12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(category.icon, size: VboxTypography.s14, color: textColor),
                const SizedBox(width: VboxSpacing.compact),
                Text(
                  category.label,
                  style: TextStyle(
                    fontSize: VboxTypography.s15,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                    color: textColor,
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

/// 福利平台（名称 + 图标 + 可选渐变覆盖）。
@immutable
class VboxWelfarePlatform {
  /// 构造。
  const VboxWelfarePlatform({
    required this.name,
    required this.icon,
    this.platformKey,
    this.gradient,
  });

  /// 平台名（用于取色与显示）。
  final String name;

  /// 平台图标。
  final IconData icon;

  /// 平台唯一键（路由回查用；`null` 时仅作纯展示）。
  final String? platformKey;

  /// 渐变色（`null` → 由 [name] 稳定哈希取 [VboxColors.welfarePlatformPalette]）。
  final List<Color>? gradient;

  /// 解析后的渐变。
  List<Color> get resolvedGradient =>
      gradient ?? VboxColors.welfarePlatformGradient(name);
}

/// 福利平台图标网格（4 列，对齐 iOS `LazyVGrid` + `RemotePlatformIconCard`）。
///
/// 只做布局与点击回调，平台数据由调用方注入（H-06 接入远程源）。
/// [onLongPress] 供长按进入编辑排序（对齐 iOS `onLongPressGesture` 入口）。
class VboxWelfarePlatformGrid extends StatelessWidget {
  /// 构造。
  const VboxWelfarePlatformGrid({
    super.key,
    required this.platforms,
    this.onTap,
    this.onLongPress,
    this.columns = 4,
  });

  /// 平台列表。
  final List<VboxWelfarePlatform> platforms;

  /// 点击回调。
  final ValueChanged<VboxWelfarePlatform>? onTap;

  /// 长按回调（进入编辑排序）。
  final VoidCallback? onLongPress;

  /// 列数（默认 4，对齐 iOS）。
  final int columns;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < platforms.length; i += columns) {
      final List<Widget> cells = <Widget>[];
      for (int j = 0; j < columns; j++) {
        if (j > 0) cells.add(const SizedBox(width: VboxSpacing.lg));
        final int index = i + j;
        cells.add(
          Expanded(
            child: index < platforms.length
                ? _card(context, platforms[index])
                : const SizedBox.shrink(),
          ),
        );
      }
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : VboxSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: cells,
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  Widget _card(BuildContext context, VboxWelfarePlatform platform) {
    final List<Color> gradient = platform.resolvedGradient;
    return Semantics(
      // UI-D4 辅助功能：福利平台入口。
      label: platform.name,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap == null
              ? null
              : () {
                  // UI-B1 触感反馈：对齐 iOS 福利平台入口 medium 震动。
                  VboxHaptics.medium();
                  onTap!(platform);
                },
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(VboxRadii.r16),
          child: SizedBox(
            height: 86,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: gradient,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(VboxRadii.r16),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: gradient.first.withValues(alpha: 0.3),
                        blurRadius: 6,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Icon(platform.icon, size: 24, color: Colors.white),
                ),
                const SizedBox(height: VboxSpacing.compact),
                Text(
                  platform.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: VboxTypography.s12,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
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
