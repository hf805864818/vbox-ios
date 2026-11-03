//
//  music_media_plugin.h
//  Runner
//
//  批次 D · D3：音乐媒体会话平台通道（Windows 腿，SMTC）。
//
//  与 Dart `NativeMusicMediaSession` / Android `MusicMediaSessionPlugin.kt` /
//  macOS `MusicMediaSessionPlugin.swift` 同一 wire 协议：
//    · MethodChannel `com.vbox.player/music_media`：update / clear
//    · EventChannel `com.vbox.player/music_media/events`：
//      {command: play|pause|toggle|next|previous|seek, positionMs?}
//
//  后端口径：Windows 系统媒体传输控件（SMTC，对齐 iOS MPNowPlayingInfoCenter +
//  MPRemoteCommandCenter 语义）：
//    - update → PlaybackStatus + MediaProperties + Timeline（进度/时长）+
//      封面（RandomAccessStreamReference 异步加载，失败静默）；
//    - clear → 状态 Closed + 清空元数据 + 全按钮禁用（对齐 iOS 停止清理）；
//    - ButtonPressed（Play/Pause/PlayPauseToggle/Next/Previous）与
//      PlaybackPositionChangeRequested（seek）→ EventChannel 回派。
//
//  注：SMTC 需窗口关联（ISystemMediaTransportControlsInterop::GetForWindow），
//  hwnd 由 flutter_window.cpp 传主窗口句柄（与 FloatingPlugin 同模式）。
//

#ifndef RUNNER_MUSIC_MEDIA_PLUGIN_H_
#define RUNNER_MUSIC_MEDIA_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <windows.h>

#include <memory>
#include <mutex>
#include <string>

namespace vbox {

// SMTC 状态体（winrt 对象 PIMPL，避免头文件引入 cppwinrt）。
struct SmtcState;

class MusicMediaPlugin : public flutter::Plugin {
 public:
  MusicMediaPlugin(flutter::PluginRegistrarWindows* registrar, HWND owner);

  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar, HWND owner);

  ~MusicMediaPlugin() override;

  // sink 管理（EventChannel 回调类直接调用；SMTC 线程快照发送）。
  void SetSink(
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);
  void ClearSink();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // update / clear（方法面）。
  void Update(const flutter::EncodableMap& args);
  void Clear();

  // SMTC 懒建（首次 update 建；clear 不销毁只复位）。
  void EnsureSmtc();
  void ReleaseSmtc();

  // 命令回派（SMTC 回调线程安全：sink 快照 + mutex）。
  void EmitCommand(const std::string& command, int position_ms = -1);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  std::mutex sink_mutex_;

  HWND owner_ = nullptr;
  std::unique_ptr<SmtcState> smtc_;
};

}  // namespace vbox

#endif  // RUNNER_MUSIC_MEDIA_PLUGIN_H_
