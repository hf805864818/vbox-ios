/// 平台层：屏幕亮度 / 系统音量（第 3 批 · UI-F1 视频区手势）。
///
/// 对齐 iOS 手势调节两路落点（[PlayerViewsV2_Extensions.swift](../../../../vbox/Views/PlayerViewsV2_Extensions.swift)）：
///  - 屏幕亮度：`UIScreen.main.brightness`（L97）；
///  - 系统音量：`SystemVolumeController`（`MPVolumeView`，L510-L533）。
///
/// 通道方法：`getBrightness` / `setBrightness` / `getVolume` / `setVolume`
/// （通道名 `com.vbox.player/screen_controls`）；原生未接入时经
/// [SessionScreenControlsBridge] 回退**进程内会话值**，保证手势可用且可测
/// （D28 口径：三端原生接线归平台批次）。
library;

import 'package:flutter/services.dart';

/// 屏幕控制桥（亮度 / 系统音量；可注入，测试用 fake）。
abstract class ScreenControlsBridge {
  /// 读取当前屏幕亮度（0.0 ~ 1.0；读不到回 0.5）。
  Future<double> getBrightness();

  /// 设置屏幕亮度（0.0 ~ 1.0）。
  Future<void> setBrightness(double value);

  /// 读取当前系统音量（0.0 ~ 1.0；读不到回 0.5）。
  Future<double> getVolume();

  /// 设置系统音量（0.0 ~ 1.0）。
  Future<void> setVolume(double value);
}

/// 钳制到 0.0 ~ 1.0。
double clamp01(double value) => value < 0 ? 0 : (value > 1 ? 1 : value);

/// 真实平台通道实现（Android / iOS 原生 ↔ Dart）。
class MethodChannelScreenControlsBridge implements ScreenControlsBridge {
  /// 构造。
  MethodChannelScreenControlsBridge({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.vbox.player/screen_controls');

  final MethodChannel _channel;

  @override
  Future<double> getBrightness() async {
    try {
      final double? v = await _channel.invokeMethod<double>('getBrightness');
      return clamp01(v ?? 0.5);
    } on PlatformException {
      return 0.5;
    } on MissingPluginException {
      return 0.5;
    }
  }

  @override
  Future<void> setBrightness(double value) async {
    try {
      await _channel.invokeMethod<void>('setBrightness', clamp01(value));
    } on PlatformException {
      // 原生侧失败：忽略（手势不因调节失败而中断）。
    } on MissingPluginException {
      // 未接入：忽略。
    }
  }

  @override
  Future<double> getVolume() async {
    try {
      final double? v = await _channel.invokeMethod<double>('getVolume');
      return clamp01(v ?? 0.5);
    } on PlatformException {
      return 0.5;
    } on MissingPluginException {
      return 0.5;
    }
  }

  @override
  Future<void> setVolume(double value) async {
    try {
      await _channel.invokeMethod<void>('setVolume', clamp01(value));
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }
}

/// 进程内会话实现（桌面未接入 / 单测）：维持内存值，不触原生。
class SessionScreenControlsBridge implements ScreenControlsBridge {
  /// 构造。
  SessionScreenControlsBridge({double brightness = 0.5, double volume = 0.5})
      : _brightness = clamp01(brightness),
        _volume = clamp01(volume);

  double _brightness;
  double _volume;

  @override
  Future<double> getBrightness() async => _brightness;

  @override
  Future<void> setBrightness(double value) async => _brightness = clamp01(value);

  @override
  Future<double> getVolume() async => _volume;

  @override
  Future<void> setVolume(double value) async => _volume = clamp01(value);
}
