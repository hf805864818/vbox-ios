//
//  floating_plugin.h
//  Runner
//
//  批次 D · D2：应用内浮窗平台通道（Windows 腿，桌面唯一 PiP 兜底形态）。
//
//  对齐 iOS `PiPHelper.showFloatingWindow`（PlayerViewsV2.swift:328-509）：
//   - 独立 `WS_EX_TOPMOST` 无边框小窗（默认右下 200×112）承载 Dart 传来的
//     播放器截图（RepaintBoundary → PNG bytes），`update` 换图；
//   - 手势三件套：单击 → toggle 播放 / 双击 → 恢复全屏 / 拖动（HTCAPTION
//     系统拖动）+ 松手吸附最近左右边缘；
//   - 右上关闭按钮区域（对齐 xmark.circle.fill closeBtn）。
//
//  MethodChannel `com.vbox.player/floating`：isAvailable / show / update /
//  hide / dispose；EventChannel `com.vbox.player/floating/events`：
//  {type: tap|doubleTap|close}。
//

#ifndef RUNNER_FLOATING_PLUGIN_H_
#define RUNNER_FLOATING_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace vbox {

class FloatingPlugin : public flutter::Plugin {
 public:
  // [owner] 为主窗口句柄（浮窗无 owner 直接置顶亦可；传 nullptr 亦可工作）。
  FloatingPlugin(flutter::PluginRegistrarWindows* registrar, HWND owner);

  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar, HWND owner);

  ~FloatingPlugin() override;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool ShowWindow(const uint8_t* png, size_t size, double width, double height);
  void UpdateSnapshot(const uint8_t* png, size_t size);
  void HideWindow();
  void DestroyWindow();

  static LRESULT CALLBACK WndProcStatic(HWND hwnd, UINT message, WPARAM wparam,
                                        LPARAM lparam);
  LRESULT WndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  void Emit(const char* type);
  void SnapToEdge();

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  flutter::EventSink<flutter::EncodableValue>* sink_ = nullptr;

  HWND owner_ = nullptr;
  HWND hwnd_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  ULONG_PTR gdiplus_token_ = 0;
  int width_ = 0;
  int height_ = 0;
};

}  // namespace vbox

#endif  // RUNNER_FLOATING_PLUGIN_H_
