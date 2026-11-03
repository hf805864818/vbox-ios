/// 平台层：系统信息桥（G-02-C：UiForm 真机判定）。
///
/// 对应原生侧：Android `SystemPlugin.kt`（MethodChannel `com.vbox.system/system`，
/// 方法 `getUiModeType` / `hasLeanbackFeature` / `hasTouchscreen`，对齐方案 §T.1）。
/// 非 Android 平台 / 测试环境：通道不可用 → 三方法均返回 false（非 TV），
/// 上层按编译期平台常量兜底（桌面端 → 横屏形态，A-05 形态模型）。
///
/// 设计：`SystemBridge` 抽象可注入 —— 单测使用 fake 实现，运行环境使用
/// [MethodChannelSystemBridge]（异常时安全回退 false，不抛）。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// 系统桥接口（fake 与真实实现共用）。
abstract class SystemBridge {
  /// 系统 UI Mode 是否为电视（UI_MODE_TYPE_TELEVISION）。
  Future<bool> getUiModeType();

  /// 设备是否声明 Leanback（电视）特性。
  Future<bool> hasLeanbackFeature();

  /// 设备是否声明触屏特性。
  Future<bool> hasTouchscreen();
}

/// `MethodChannel` 实现：调用 Android `SystemPlugin`。
class MethodChannelSystemBridge implements SystemBridge {
  MethodChannelSystemBridge({String? channelName})
      : _channel = MethodChannel(channelName ?? defaultChannelName);

  /// 通道名（与 Android 侧 `SystemPlugin` 一致）。
  static const String defaultChannelName = 'com.vbox.system/system';

  final MethodChannel _channel;

  Future<bool> _invoke(String method) async {
    try {
      final Object? r = await _channel.invokeMethod<bool>(method);
      return r == true;
    } on MissingPluginException {
      // 桌面 / 测试环境无原生插件 → 非 TV
      return false;
    } on PlatformException {
      return false;
    } on TypeError {
      // 通道回传非布尔值（异常载荷）→ 安全回退非 TV，不抛
      return false;
    }
  }

  @override
  Future<bool> getUiModeType() => _invoke('getUiModeType');

  @override
  Future<bool> hasLeanbackFeature() => _invoke('hasLeanbackFeature');

  @override
  Future<bool> hasTouchscreen() => _invoke('hasTouchscreen');
}

/// 平台判定兜底（非 Android 平台走编译期常量；供 resolver 复用）。
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;
