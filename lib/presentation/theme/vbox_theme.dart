/// 主题工厂（批次 A · A-03；A2~A5 统一收口于本文件）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.1（四皮肤）· §2.2（颜色）· §2.3（字体）
/// · §1.3（跨页共性视觉规律：iOS 推入转场 / 无涟漪 / 回弹）。
///
/// 目标：消费契约键 `app_skin_mode` / `app_skin_follows_system`，为四套皮肤
/// 产出等价 [ThemeData]，并在运行时热切换（R-1 皮肤令牌一致）。
///
/// 统一收口（改此一处，全端生效）：
///   · A2 `pageTransitionsTheme` → 全端 Cupertino 推入；
///   · A3 `splashFactory` → `NoSplash`（去 Material 涟漪）；
///   · A4 `switchTheme` → iOS `UISwitch` 配色；
///   · A5 [VboxScrollBehavior] → BouncingScrollPhysics + 无辉光过卷。
library;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'tokens/colors.dart';
import 'tokens/typography.dart';

/// 主题工厂。
class VboxTheme {
  const VboxTheme._();

  /// 解析该皮肤「期望的配色模式」（`null` = 跟随系统）。
  ///
  /// 逐行对齐 iOS `AppSettings.preferredColorScheme`：
  /// ```swift
  /// if skinFollowsSystem { return skinMode == .liquid ? .dark : nil }
  /// if skinMode == .liquid { return .dark }
  /// if skinMode == .frosted { return nil }
  /// return skinMode.preferredColorScheme
  /// ```
  static Brightness? preferredBrightness(VboxSkin skin, bool followsSystem) {
    if (followsSystem) {
      return skin == VboxSkin.liquid ? Brightness.dark : null;
    }
    if (skin == VboxSkin.liquid) return Brightness.dark;
    if (skin == VboxSkin.frosted) return null;
    return skin.fixedBrightness;
  }

  /// 解析最终配色模式：皮肤固定值优先，`null` 时回退系统亮度。
  static Brightness resolveBrightness({
    required VboxSkin skin,
    required bool followsSystem,
    required Brightness systemBrightness,
  }) =>
      preferredBrightness(skin, followsSystem) ?? systemBrightness;

  /// 按皮肤 + 配色模式构建 [ThemeData]。
  static ThemeData build({
    required VboxSkin skin,
    required Brightness brightness,
  }) {
    final bool isDark = brightness == Brightness.dark;
    final Color primary = skin.primary;
    final Color systemBackground = isDark
        ? VboxColors.systemBackgroundDark
        : VboxColors.systemBackgroundLight;
    final Color groupedBackground = isDark
        ? VboxColors.secondarySystemBackgroundDark
        : VboxColors.secondarySystemBackgroundLight;
    final Color secondaryLabel =
        isDark ? VboxColors.secondaryLabelDark : VboxColors.secondaryLabelLight;

    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    ).copyWith(
      primary: primary,
      surface: systemBackground,
      surfaceContainerHighest: groupedBackground,
      onSurfaceVariant: secondaryLabel,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      // iOS `secondarySystemBackground`（分组底）为页面底色；卡片用 `surface`（系统底）。
      scaffoldBackgroundColor: groupedBackground,
      textTheme: VboxTypography.buildTextTheme(
        primaryText: scheme.onSurface,
        secondaryText: secondaryLabel,
      ),
      // ── A2 页面转场：全端统一 iOS 推入（Cupertino）────────────────
      // 对齐 §1.3「页面切换为 iOS 推入手感」：Android / Windows / macOS 的默认
      // 转场（Zoom / OpenUpwards 等）一并替换为 Cupertino 推入，全端手感一致。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
        },
      ),
      // ── A3 去涟漪：截图中未见 Material 涟漪（§1.3「交互反馈」）────────
      // `NoSplash` 关闭水波纹；`InkWell` 的按下高亮（highlight）仍保留，
      // 与 iOS「按下轻微变暗、无扩散波纹」一致。
      splashFactory: NoSplash.splashFactory,
      // ── A4 开关：对齐 iOS `UISwitch` 配色（图12 设置页 / 图16 福利弹窗）──
      // 滑块恒为白（深浅模式皆然）；轨道选中 = 皮肤主色，未选中 = systemGray4；
      // 透明描边，贴近 iOS 的实心胶囊轨道。
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll<Color>(
          VboxColors.systemBackgroundLight,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? primary
              : (isDark
                  ? VboxColors.systemGray4Dark
                  : VboxColors.systemGray4Light),
        ),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
      ),
    );
  }
}

/// 全端统一滚动行为（批次 A · A5）。
///
/// 对齐 iOS 的橡皮筋回弹手感（§1.3）：所有平台统一 [BouncingScrollPhysics]，
/// 并抑制 Android 的辉光过卷指示器（[GlowingOverscrollIndicator]）——
/// 回弹本身即反馈，避免出现截图里没有的绿色/橙色辉光。
class VboxScrollBehavior extends MaterialScrollBehavior {
  /// 构造。
  const VboxScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}