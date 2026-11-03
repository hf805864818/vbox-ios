/// 壳层 · 底部导航 Tab 定义（批次 A · A8）。
///
/// 唯一真相源：iOS `ContentView.swift` L17-L57（`Tab` 枚举与 `visibleTabs`）。
///
/// 关键口径（R-9）：
///   · 基础 4 项 `[首页, 短剧, 直播, 我的]`；
///   · `welfareEnabled && welfareUnlocked` 为真时**在 index 3 插入「福利」**（最多 5）；
///   · Tab 列表**动态可裁剪**，内容区必须由**枚举**驱动（**不是**下标），
///     否则福利 Tab 出现 / 消失时下标漂移错位（解 D15）。
library;

import 'package:flutter/material.dart';

import '../widgets/vbox/vbox_nav.dart';

/// 底部导航 Tab（顺序即基础展示顺序）。
enum AppTab {
  /// 首页（豆瓣推荐为默认内容）。
  home('首页', Icons.home_outlined, Icons.home),

  /// 短剧。
  shortDrama('短剧', Icons.smart_display_outlined, Icons.smart_display),

  /// 直播。
  live('直播', Icons.live_tv_outlined, Icons.live_tv),

  /// 福利（门控：`enabled && unlocked`）。
  welfare('福利', Icons.card_giftcard_outlined, Icons.card_giftcard),

  /// 我的（个人中心）。
  profile('我的', Icons.person_outline, Icons.person);

  const AppTab(this.label, this.icon, this.selectedIcon);

  /// 文案。
  final String label;

  /// 未选中（outline）图标。
  final IconData icon;

  /// 选中（fill）图标。
  final IconData selectedIcon;

  /// 基础 4 项（恒显示）。
  static const List<AppTab> baseTabs = <AppTab>[
    AppTab.home,
    AppTab.shortDrama,
    AppTab.live,
    AppTab.profile,
  ];

  /// 福利 Tab 插入位置（对齐 iOS `insert(.welfare, at: 3)`）。
  static const int welfareIndex = 3;

  /// 按门控解析可见 Tab（对齐 iOS `ContentView.visibleTabs`）。
  static List<AppTab> visibleTabs({required bool welfareVisible}) {
    final List<AppTab> tabs = <AppTab>[...baseTabs];
    if (welfareVisible) tabs.insert(welfareIndex, AppTab.welfare);
    return tabs;
  }

  /// 转导航项（供 [VboxBottomNav] 消费）。
  VboxNavItem toNavItem() =>
      VboxNavItem(icon: icon, selectedIcon: selectedIcon, label: label);
}