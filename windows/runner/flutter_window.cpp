#include "flutter_window.h"

#include <optional>

#include <flutter/plugin_registrar_windows.h>

#include "flutter/generated_plugin_registrant.h"
#include "floating_plugin.h"
#include "music_media_plugin.h"
#include "node_lifecycle_plugin.h"
#include "player_plugin.h"
#include "screen_controls_plugin.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // 批次 C · C-11：Windows 播放器插件（libmpv 主后端）手动注册
  // （非插件工程无 generated registrant，与 macOS MainFlutterWindow 的
  //  PlayerPlugin.register 同模式）。
  // 注：GetRegistrar 参数为 FlutterDesktopPluginRegistrarRef（指针），
  // 需先经 engine()->GetRegistrarForPlugin 取 registrar，而非传插件名。
  vbox::PlayerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(
              flutter_controller_->engine()->GetRegistrarForPlugin(
                  "PlayerPlugin")));
  // ND-01 补充：Node 子进程生命周期绑定（Job Object），主进程退出/崩溃时
  // 由 OS 连带终结 node.exe 孤儿，杜绝「Node 端口 58080 已被占用」。
  vbox::NodeLifecyclePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(
              flutter_controller_->engine()->GetRegistrarForPlugin(
                  "NodeLifecyclePlugin")));
  // 批次 D：D1 亮度/音量、D2 浮窗、D3 媒体会话手动注册（同 PlayerPlugin 模式）。
  // 浮窗 owner 与 SMTC GetForWindow 均需主窗口 HWND（OnCreate 时窗口已建）。
  vbox::ScreenControlsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(
              flutter_controller_->engine()->GetRegistrarForPlugin(
                  "ScreenControlsPlugin")));
  {
    HWND main_window = GetHandle();
    vbox::FloatingPlugin::RegisterWithRegistrar(
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrarWindows>(
                flutter_controller_->engine()->GetRegistrarForPlugin(
                    "FloatingPlugin")),
        main_window);
    vbox::MusicMediaPlugin::RegisterWithRegistrar(
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrarWindows>(
                flutter_controller_->engine()->GetRegistrarForPlugin(
                    "MusicMediaPlugin")),
        main_window);
  }
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 主窗口关闭走 WM_DESTROY，Flutter 引擎随后销毁 Dart isolate，Dart 侧的
  // detached→stop() 异步链路可能来不及完成；这里在 UI 线程同步终结已收编进
  // Job Object 的 node.exe，确定性避免 node 残留成孤儿继续占用 58080 端口。
  vbox::NodeLifecyclePlugin::TerminateAll();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
