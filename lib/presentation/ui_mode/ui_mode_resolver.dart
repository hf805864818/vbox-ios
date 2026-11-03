/// 形态判定（UI Form Resolver）· 批次 A · A-05。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.2（形态解析）。
///
/// 口径收敛（A-05）：原 `UiMode{phone,tv,desktop}` **三形态**改造为
/// `UiForm{portrait,landscape}` **双形态**（版式只分竖/横）+
/// `InputModality{touch,remote,mouseKeyboard}`（只影响焦点与交互反馈，**不改版式**）。
/// 原三形态语义由「形态 + 输入模态」共同表达：
///   手机竖屏 → portrait/touch · 手机横屏 → landscape/touch ·
///   桌面 → landscape/mouseKeyboard · TV → landscape/remote。
///
/// 判定优先级（高 → 低，方案 §3.2）：
///   ① 用户功能开关 `app_ui_form_override`（`auto|portrait|landscape`）
///   ② 平台特征（TV / PC / mac 恒横屏）
///   ③ 窗口最短边（`MediaQuery.shortestSide` ≥ 600dp → 横屏）
///   ④ 方向（`MediaQuery.orientation`）
///
/// 视口（尺寸 / 方向）随 `MediaQuery` 变化，由调用方在 build 时注入
/// [UiFormController.resolveAt]（保持响应式）；控制器仅持有「设备能力 + 用户覆盖」
/// 这一稳定基底，避免在 build 中改写状态。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../platform/system/system_bridge.dart';

/// 显示形态（本轮收敛为 2 种，方案 §3.2）。
enum UiForm {
  /// 竖屏（手机竖握；底部胶囊 TabBar）。
  portrait,

  /// 横屏（TV / PC / mac / 手机横屏 / 平板；左侧 NavigationRail）。
  landscape;

  /// 是否竖屏。
  bool get isPortrait => this == UiForm.portrait;

  /// 是否横屏。
  bool get isLandscape => this == UiForm.landscape;
}

/// 输入模态（方案 §3.4：只加反馈层，不改版式）。
enum InputModality {
  /// 触摸（点击 / 长按 / 滑动）。
  touch,

  /// 遥控 D-pad（焦点遍历 / 可见焦点环 / OK·返回·菜单映射）。
  remote,

  /// 鼠标键盘（hover / 右键 / 快捷键）。
  mouseKeyboard,
}

/// 显示模式覆盖档（契约键 `app_ui_form_override`，批次 A · A-06）。
enum UiFormOverride {
  /// 自动（平台 + 尺寸 + 方向判定）。
  auto('auto', '自动'),

  /// 强制手机竖屏。
  portrait('portrait', '手机（竖屏）'),

  /// 强制大屏横屏。
  landscape('landscape', '大屏（横屏）');

  const UiFormOverride(this.id, this.title);

  /// 契约字符串值（写入 `app_ui_form_override`）。
  final String id;

  /// 中文显示名（设置项 §I-04）。
  final String title;

  /// 契约默认档（`app_ui_form_override` 默认 `auto`）。
  static const UiFormOverride fallback = UiFormOverride.auto;

  /// 解析契约字符串（未知值回退 [fallback]）。
  static UiFormOverride fromId(String? id) {
    for (final UiFormOverride o in UiFormOverride.values) {
      if (o.id == id) return o;
    }
    return fallback;
  }
}

/// 形态判定输入（纯数据；便于单测穷举分支）。
@immutable
class UiFormEnv {
  const UiFormEnv({
    this.override = UiFormOverride.auto,
    this.isTv = false,
    this.isDesktop = false,
    this.shortestSide = 0,
    this.orientation = Orientation.portrait,
    this.hasTouch = true,
    this.hasDpad = false,
    this.hasPointer = false,
  });

  /// 用户功能开关（最高优先）。
  final UiFormOverride override;

  /// 是否 Android TV（平台通道三重判定结果）。
  final bool isTv;

  /// 是否桌面平台（PC / mac / web，编译期常量）。
  final bool isDesktop;

  /// 窗口最短边（dp）。
  final double shortestSide;

  /// 当前方向。
  final Orientation orientation;

  /// 是否具备触屏。
  final bool hasTouch;

  /// 是否具备遥控 D-pad。
  final bool hasDpad;

  /// 是否具备鼠标指针。
  final bool hasPointer;

  /// 注入视口（尺寸 + 方向），保留设备能力与用户覆盖。
  UiFormEnv withViewport({
    required Size size,
    required Orientation orientation,
  }) =>
      UiFormEnv(
        override: override,
        isTv: isTv,
        isDesktop: isDesktop,
        shortestSide: size.shortestSide,
        orientation: orientation,
        hasTouch: hasTouch,
        hasDpad: hasDpad,
        hasPointer: hasPointer,
      );
}

/// 形态解析器（纯函数，无 IO / 无原生依赖）。
class UiFormResolver {
  const UiFormResolver._();

  /// 大屏断点：最短边 ≥ 600dp 视为大屏（方案 §3.2 ③）。
  static const double largeScreenBreakpoint = 600;

  /// 解析显示形态（方案 §3.2 `resolveForm`）。
  static UiForm resolve(UiFormEnv env) {
    // ① 用户功能开关（最高优先）
    switch (env.override) {
      case UiFormOverride.portrait:
        return UiForm.portrait;
      case UiFormOverride.landscape:
        return UiForm.landscape;
      case UiFormOverride.auto:
        break;
    }
    // ② 平台特征：TV / PC / mac 恒横屏
    if (env.isTv || env.isDesktop) return UiForm.landscape;
    // ③ 窗口最短边：平板 / 折叠展开按横屏
    if (env.shortestSide >= largeScreenBreakpoint) return UiForm.landscape;
    // ④ 方向：手机随方向
    return env.orientation == Orientation.landscape
        ? UiForm.landscape
        : UiForm.portrait;
  }

  /// 解析输入模态（方案 §3.4）。
  static InputModality resolveModality(UiFormEnv env) {
    if (env.isTv || (env.hasDpad && !env.hasTouch)) return InputModality.remote;
    if (env.isDesktop || (env.hasPointer && !env.hasTouch)) {
      return InputModality.mouseKeyboard;
    }
    return InputModality.touch;
  }
}

/// 运行平台探测（可注入以隔离平台分支；单测用）。
@immutable
class UiFormPlatform {
  const UiFormPlatform({required this.isDesktop, required this.isAndroid});

  /// 按编译期常量 / `dart:io` 探测当前平台。
  factory UiFormPlatform.detect() => UiFormPlatform(
        isDesktop: kIsWeb || isDesktopPlatform,
        isAndroid: Platform.isAndroid,
      );

  /// 是否桌面平台（PC / mac / web）。
  final bool isDesktop;

  /// 是否 Android。
  final bool isAndroid;
}

/// 形态控制器：持有「设备能力 + 用户覆盖」基底并广播变更。
///
/// 视口（尺寸 / 方向）不驻留状态 —— 由 [resolveAt] 在 build 时注入，保持
/// `MediaQuery` 响应式且不在 build 中触发 `notifyListeners`。
class UiFormController extends ChangeNotifier {
  UiFormController({UiFormEnv env = const UiFormEnv()}) : _env = env;

  UiFormEnv _env;

  /// 当前基底环境。
  UiFormEnv get env => _env;

  /// 用户显示模式覆盖档。
  UiFormOverride get override => _env.override;

  /// 输入模态（由设备能力推导）。
  InputModality get modality => UiFormResolver.resolveModality(_env);

  /// 基底环境变更（设备能力 / 用户覆盖）。
  void applyBase(UiFormEnv env) {
    _env = env;
    notifyListeners();
  }

  /// 用户显示模式覆盖变更（I-04 设置项接线；调用方负责持久化契约键）。
  void setOverride(UiFormOverride override) {
    applyBase(UiFormEnv(
      override: override,
      isTv: _env.isTv,
      isDesktop: _env.isDesktop,
      shortestSide: _env.shortestSide,
      orientation: _env.orientation,
      hasTouch: _env.hasTouch,
      hasDpad: _env.hasDpad,
      hasPointer: _env.hasPointer,
    ));
  }

  /// 按当前视口解析形态（响应式；不改控制器状态）。
  UiForm resolveAt({
    required Size size,
    required Orientation orientation,
  }) =>
      UiFormResolver.resolve(
        _env.withViewport(size: size, orientation: orientation),
      );

  /// 真机接线入口（A-05 / 沿用 G-02-C 平台通道）。
  ///
  /// 仅 Android 走通道三重判定（TV + 触屏能力）；桌面端走编译期常量兜底
  /// （**不触碰通道**）；其余平台按触屏手机处理。
  /// [platform] / [tvJudge] / [touchJudge] 可注入以隔离平台分支（单测用）。
  Future<void> resolveWithBridge(
    SystemBridge bridge, {
    Size? screenSize,
    Orientation orientation = Orientation.portrait,
    UiFormOverride? override,
    UiFormPlatform? platform,
    Future<bool> Function(SystemBridge bridge)? tvJudge,
    Future<bool> Function(SystemBridge bridge)? touchJudge,
  }) async {
    final UiFormPlatform p = platform ?? UiFormPlatform.detect();
    bool isTv = false;
    bool hasTouch = !p.isDesktop;
    if (!p.isDesktop && p.isAndroid) {
      isTv = await (tvJudge ?? _defaultTvJudge)(bridge);
      hasTouch = await (touchJudge ?? bridge.hasTouchscreen)();
    }
    applyBase(UiFormEnv(
      override: override ?? _env.override,
      isTv: isTv,
      isDesktop: p.isDesktop,
      shortestSide: screenSize?.shortestSide ?? 0,
      orientation: orientation,
      hasTouch: hasTouch,
      hasDpad: isTv,
      hasPointer: p.isDesktop,
    ));
  }

  /// 默认 TV 判定：`getUiModeType`（官方标准）优先，`hasLeanbackFeature` 兜底。
  static Future<bool> _defaultTvJudge(SystemBridge bridge) async {
    if (await bridge.getUiModeType()) return true;
    return bridge.hasLeanbackFeature();
  }
}