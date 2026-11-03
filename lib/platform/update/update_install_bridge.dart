/// 平台层：自更新安装桥（批次 K · K-更3 Dart 侧）。
///
/// 对应原生侧：Android `UpdatePlugin.kt`（MethodChannel `com.vbox.system/update`，
/// 方法 `canInstall` / `openInstallPermissionSettings` / `installApk`）。
///
/// 对齐 iOS `UpdateManager.installIPA()` 的「分平台分派安装」语义：
/// Android 走应用内安装器；桌面端（Windows / macOS）由 `Updater` 走
/// 「系统默认程序打开安装包 → 发布页兜底」。
///
/// 设计：`UpdateInstallBridge` 抽象可注入 —— 单测用 fake；
/// 运行环境用 [MethodChannelUpdateInstallBridge]（通道不可用 / 异常时安全回退，不抛）。
library;

import 'package:flutter/services.dart';

/// 安装结果状态（契约值，与 Android `UpdatePlugin` 回传一致）。
abstract final class UpdateInstallStatus {
  /// 已拉起系统安装器。
  static const String started = 'started';

  /// 未获「安装未知应用」授权，已引导授权页。
  static const String needPermission = 'needPermission';

  /// 安装失败（文件缺失 / 异常）。
  static const String failed = 'failed';

  /// 当前平台无原生安装通道（桌面 / 测试环境）。
  static const String unsupported = 'unsupported';
}

/// 安装桥接口（fake 与真实实现共用）。
abstract class UpdateInstallBridge {
  /// 当前是否已获应用内安装授权（Android「安装未知应用」）。
  Future<bool> canInstall();

  /// 跳系统「安装未知应用」授权页。
  Future<void> openInstallPermissionSettings();

  /// 拉起安装器安装 [path] 处的安装包，返回 [UpdateInstallStatus] 之一。
  Future<String> installApk(String path);
}

/// `MethodChannel` 实现：调用 Android `UpdatePlugin`。
class MethodChannelUpdateInstallBridge implements UpdateInstallBridge {
  /// 构造。
  MethodChannelUpdateInstallBridge({String? channelName})
      : _channel = MethodChannel(channelName ?? defaultChannelName);

  /// 通道名（与 Android `UpdatePlugin.CHANNEL` 一致）。
  static const String defaultChannelName = 'com.vbox.system/update';

  final MethodChannel _channel;

  @override
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') == true;
    } on MissingPluginException {
      // 桌面 / 测试环境无原生插件 → 无应用内安装能力
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> openInstallPermissionSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
    } on MissingPluginException {
      // 桌面 / 测试环境无原生插件
    } on PlatformException {
      // 引导页拉起失败不阻断主流程
    }
  }

  @override
  Future<String> installApk(String path) async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'installApk',
        <String, Object?>{'path': path},
      );
      return r?['status']?.toString() ?? UpdateInstallStatus.failed;
    } on MissingPluginException {
      return UpdateInstallStatus.unsupported;
    } on PlatformException {
      return UpdateInstallStatus.failed;
    }
  }
}