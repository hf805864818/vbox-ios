//
//  screen_controls_plugin.cpp
//  Runner
//
//  批次 D · D1 —— 实现见头文件注释。
//

#include "screen_controls_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <endpointvolume.h>
#include <mmdeviceapi.h>

namespace vbox {

namespace {

constexpr char kChannelName[] = "com.vbox.player/screen_controls";

// 桌面亮度：无通用系统 API → 会话级内存值（登记）。
double g_session_brightness = 0.5;

class ComGuard {
 public:
  ComGuard() {
    hr_ = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (hr_ == RPC_E_CHANGED_MODE) {
      hr_ = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    }
    initialized_ = SUCCEEDED(hr_);
  }
  ~ComGuard() {
    if (initialized_) CoUninitialize();
  }
  bool ok() const { return initialized_; }

 private:
  HRESULT hr_ = S_OK;
  bool initialized_ = false;
};

// 取默认输出设备的音量接口执行动作（每次即取，设备切换天然跟随）。
bool WithEndpointVolume(bool (*action)(IAudioEndpointVolume*, void*),
                        void* ctx) {
  ComGuard com;
  if (!com.ok()) return false;
  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) return false;
  IMMDevice* device = nullptr;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device);
  enumerator->Release();
  if (FAILED(hr)) return false;
  IAudioEndpointVolume* endpoint = nullptr;
  hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(&endpoint));
  device->Release();
  if (FAILED(hr)) return false;
  const bool ok = action(endpoint, ctx);
  endpoint->Release();
  return ok;
}

bool ReadVolume(IAudioEndpointVolume* endpoint, void* ctx) {
  float volume = 0.5f;
  if (FAILED(endpoint->GetMasterVolumeLevelScalar(&volume))) return false;
  *static_cast<double*>(ctx) = static_cast<double>(volume);
  return true;
}

bool WriteVolume(IAudioEndpointVolume* endpoint, void* ctx) {
  const float volume = static_cast<float>(*static_cast<double*>(ctx));
  return SUCCEEDED(endpoint->SetMasterVolumeLevelScalar(volume, nullptr));
}

}  // namespace

void ScreenControlsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<ScreenControlsPlugin>(registrar);
  auto* raw = plugin.get();
  // MethodCallHandler 持裸指针（插件所有权在 registrar，析构序安全）。
  raw->channel_->SetMethodCallHandler(
      [raw](const auto& call, auto result) {
        raw->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

ScreenControlsPlugin::ScreenControlsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {}

void ScreenControlsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "getBrightness") {
    result->Success(flutter::EncodableValue(g_session_brightness));
    return;
  }
  if (call.method_name() == "setBrightness") {
    if (const auto* v = std::get_if<double>(call.arguments())) {
      g_session_brightness = std::max(0.0, std::min(1.0, *v));
    }
    result->Success(flutter::EncodableValue(nullptr));
    return;
  }
  if (call.method_name() == "getVolume") {
    double volume = 0.5;
    if (!WithEndpointVolume(ReadVolume, &volume)) volume = 0.5;
    result->Success(flutter::EncodableValue(volume));
    return;
  }
  if (call.method_name() == "setVolume") {
    if (const auto* v = std::get_if<double>(call.arguments())) {
      double clamped = std::max(0.0, std::min(1.0, *v));
      WithEndpointVolume(WriteVolume, &clamped);
    }
    result->Success(flutter::EncodableValue(nullptr));
    return;
  }
  result->NotImplemented();
}

double ScreenControlsPlugin::GetVolume() {
  double volume = 0.5;
  WithEndpointVolume(ReadVolume, &volume);
  return volume;
}

void ScreenControlsPlugin::SetVolume(double value) {
  double clamped = std::max(0.0, std::min(1.0, value));
  WithEndpointVolume(WriteVolume, &clamped);
}

}  // namespace vbox
