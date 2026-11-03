//
//  screen_controls_plugin.h
//  Runner
//
//  批次 D · D1：屏幕亮度 / 系统音量平台通道（Windows 腿）。
//
//  MethodChannel `com.vbox.player/screen_controls`（与 Dart
//  `MethodChannelScreenControlsBridge` / Android `ScreenControlsPlugin.kt` /
//  macOS `ScreenControlsPlugin.swift` 同一 wire 协议）：
//    getBrightness / setBrightness / getVolume / setVolume。
//
//  差异登记（对齐实施方案 D1）：
//   - 音量：Core Audio `IAudioEndpointVolume` 系统主音量（对齐 iOS
//     `MPVolumeView` 语义）；
//   - 亮度：Windows 无通用系统亮度 API（笔记本 ACPI 厂商各异）→ 会话级
//     内存值（桌面亮度为会话级，登记）。
//

#ifndef RUNNER_SCREEN_CONTROLS_PLUGIN_H_
#define RUNNER_SCREEN_CONTROLS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace vbox {

class ScreenControlsPlugin : public flutter::Plugin {
 public:
  explicit ScreenControlsPlugin(flutter::PluginRegistrarWindows* registrar);

  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  double GetVolume();
  void SetVolume(double value);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace vbox

#endif  // RUNNER_SCREEN_CONTROLS_PLUGIN_H_
