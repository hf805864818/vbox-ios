/// 自适应框架 · 自适应外壳（批次 A · A-07 / A8）。
///
/// 唯一真相源：决策 2026-10-03（§1.5(1)，R-9）——
/// **全端（Android / Android TV / Windows / macOS）统一「底部悬浮胶囊 TabBar」**，
/// 不做左侧 NavigationRail、不做顶栏 Tab；[form] 只影响内容最大宽度约束，
/// **不再改变导航形式**（原「横屏 → 左侧 Rail」分支已废弃，解 D18）。
///
/// 一套页面代码：导航项 [items] 与内容 [body] 全端共用。
library;

import 'package:flutter/material.dart';

import '../../ui_mode/ui_mode.dart';
import '../../theme/tokens/colors.dart';
import '../vbox/vbox_nav.dart';

/// 自适应外壳：全端底部悬浮胶囊 TabBar，内容区按形态约束最大宽度。
class AdaptiveScaffold extends StatelessWidget {
  /// 构造。
  const AdaptiveScaffold({
    super.key,
    required this.form,
    required this.body,
    this.items = const <VboxNavItem>[],
    this.selectedIndex = 0,
    this.onSelected,
    this.title,
    this.actions = const <Widget>[],
    this.tabBarPalette,
    this.hideTabBar = false,
    this.maxContentWidth = 1680,
    this.backgroundColor,
  });

  /// 当前形态（只影响内容最大宽度约束；不改导航形式）。
  final UiForm form;

  /// 内容区（全端共用）。
  final Widget body;

  /// 导航项（空则不渲染导航）。
  final List<VboxNavItem> items;

  /// 当前选中索引。
  final int selectedIndex;

  /// 选择回调。
  final ValueChanged<int>? onSelected;

  /// 顶栏标题（null → 不渲染 AppBar）。
  final String? title;

  /// 顶栏操作。
  final List<Widget> actions;

  /// 底栏配色（缺省按浅色皮肤 + 当前亮度）。
  final VboxTabBarPalette? tabBarPalette;

  /// 是否整体隐藏底栏（`isTabBarHidden`，L 批次播放页使用）。
  final bool hideTabBar;

  /// 内容区最大宽度（横屏居中约束）。
  final double maxContentWidth;

  /// 底色（缺省取主题）。
  final Color? backgroundColor;

  /// 内容区：横屏居中 + 最大宽度约束；竖屏铺满。
  Widget _content(BuildContext context) {
    if (!form.isLandscape) return body;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxContentWidth),
        child: body,
      ),
    );
  }

  PreferredSizeWidget? _appBar() {
    if (title == null) return null;
    return AppBar(
      title: Text(title!),
      actions: actions,
      backgroundColor: backgroundColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool showNav = items.isNotEmpty && !hideTabBar;
    return Scaffold(
      appBar: _appBar(),
      backgroundColor: backgroundColor,
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: SafeArea(child: _content(context))),
          if (showNav)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VboxBottomNav(
                items: items,
                selectedIndex: selectedIndex,
                onSelected: onSelected ?? (_) {},
                palette: tabBarPalette,
              ),
            ),
        ],
      ),
    );
  }
}