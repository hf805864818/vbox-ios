//
//  player_plugin.cpp
//  Runner
//
//  批次 C · C-11：Windows 播放器插件（libmpv 主后端）实现。
//  协议与架构说明见 player_plugin.h 文件头注释。

#include "player_plugin.h"

#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <string>
#include <utility>
#include <variant>

#include <flutter/event_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include "baidu_token_bridge.h"

namespace vbox {

namespace {

// ─────────────── EncodableValue 解析辅助（Dart 侧 open 参数） ───────────────

const flutter::EncodableMap* AsMap(const flutter::EncodableValue* value) {
  if (value == nullptr || !std::holds_alternative<flutter::EncodableMap>(*value)) {
    return nullptr;
  }
  return &std::get<flutter::EncodableMap>(*value);
}

std::string GetString(const flutter::EncodableMap& map, const std::string& key,
                      const std::string& fallback = "") {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end() || !std::holds_alternative<std::string>(it->second)) {
    return fallback;
  }
  return std::get<std::string>(it->second);
}

bool GetBool(const flutter::EncodableMap& map, const std::string& key,
             bool fallback = false) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end() || !std::holds_alternative<bool>(it->second)) {
    return fallback;
  }
  return std::get<bool>(it->second);
}

// headers（Dart Map<String,String>）→ mpv http-header-fields 选项串。
std::string JoinHeaders(const flutter::EncodableMap& map) {
  const auto it = map.find(flutter::EncodableValue("headers"));
  if (it == map.end() || !std::holds_alternative<flutter::EncodableMap>(it->second)) {
    return "";
  }
  const flutter::EncodableMap& headers =
      std::get<flutter::EncodableMap>(it->second);
  std::string joined;
  for (const auto& entry : headers) {
    if (!std::holds_alternative<std::string>(entry.first) ||
        !std::holds_alternative<std::string>(entry.second)) {
      continue;
    }
    if (!joined.empty()) {
      joined += ",";
    }
    joined += std::get<std::string>(entry.first) + ": " +
              std::get<std::string>(entry.second);
  }
  return joined;
}

// ─────────────── OpenGL 常量（手动声明子集，避免引入 GL/gl.h）───────────────

constexpr GlEnum kGlTexture2D = 0x0DE1;
constexpr GlEnum kGlTextureMinFilter = 0x2801;
constexpr GlEnum kGlTextureMagFilter = 0x2800;
constexpr GlInt kGlLinear = 0x2601;
constexpr GlInt kGlRgba8 = 0x8058;
constexpr GlEnum kGlRgba = 0x1908;
constexpr GlEnum kGlUnsignedByte = 0x1401;
constexpr GlEnum kGlFramebuffer = 0x8D40;
constexpr GlEnum kGlColorAttachment0 = 0x8CE0;
constexpr GlEnum kGlFramebufferComplete = 0x8CD5;
constexpr GlEnum kGlBgra = 0x80E1;
constexpr GlEnum kGlPackAlignment = 0x0D05;

}  // namespace

// ─────────────── MpvApi：动态加载 mpv-2.dll ───────────────

bool MpvApi::Load() {
  if (loaded) {
    return true;
  }
  HMODULE mod = ::LoadLibraryW(L"mpv-2.dll");
  if (mod == nullptr) {
    // 按 GetLastError 分类（LoadLibraryW 失败 ≠ 一定是「文件缺失」：
    // 该 dll 导入 vulkan-1.dll 等非保证预装的系统组件，依赖解析失败
    // 同样返回 null）。
    const DWORD err = ::GetLastError();
    switch (err) {
      case ERROR_FILE_NOT_FOUND:
      case ERROR_PATH_NOT_FOUND:
        load_error =
            "mpv-2.dll 未随包分发（安装包不完整或被安全软件清理）";
        break;
      case ERROR_MOD_NOT_FOUND:
        load_error =
            "mpv-2.dll 依赖的运行库缺失（vulkan-1.dll 随安装包分发，"
            "请确认安装包完整；或安装显卡驱动 / Vulkan Runtime 后重试）";
        break;
      case ERROR_BAD_EXE_FORMAT:
        load_error = "mpv-2.dll 架构不匹配（需 64 位）";
        break;
      case ERROR_ACCESS_DENIED:
        load_error = "mpv-2.dll 访问被拒绝（可能被安全软件拦截）";
        break;
      default:
        load_error = "mpv-2.dll 加载失败（Win32 错误码 " +
                     std::to_string(err) + "）";
        break;
    }
    return false;
  }
  bool ok = true;
  // libmpv 导出符号统一带 `mpv_` 前缀（mpv_create / mpv_render_context_* 等）。
#define LOAD_MPV_SYM(Name)                                                 \
  do {                                                                     \
    Name = reinterpret_cast<decltype(Name)>(                               \
        ::GetProcAddress(mod, "mpv_" #Name));                              \
    if (Name == nullptr) {                                                 \
      ok = false;                                                          \
    }                                                                      \
  } while (0)
  LOAD_MPV_SYM(create);
  LOAD_MPV_SYM(initialize);
  LOAD_MPV_SYM(terminate_destroy);
  LOAD_MPV_SYM(command);
  LOAD_MPV_SYM(set_option_string);
  LOAD_MPV_SYM(set_property);
  LOAD_MPV_SYM(get_property);
  LOAD_MPV_SYM(observe_property);
  LOAD_MPV_SYM(unobserve_property);
  LOAD_MPV_SYM(wait_event);
  LOAD_MPV_SYM(error_string);
  LOAD_MPV_SYM(free);
#undef LOAD_MPV_SYM
  if (!ok) {
    ::OutputDebugStringW(
        L"vbox: mpv-2.dll 符号不完整，libmpv 后端不可用（D6 无降级，报错给 Dart）\n");
    return false;
  }
  // render API 为可选增强（R-渲1）：旧 dll 缺失时保持 nullptr → 控制面可用但无
  // 纹理输出，Dart 侧渲染深色占位（不误判为黑屏故障）。
#define LOAD_MPV_RENDER_SYM(Name)                                          \
  do {                                                                     \
    Name = reinterpret_cast<decltype(Name)>(                               \
        ::GetProcAddress(mod, "mpv_" #Name));                              \
  } while (0)
  LOAD_MPV_RENDER_SYM(request_log_messages);  // 可选：mpv 内部日志上抛。
  LOAD_MPV_RENDER_SYM(render_context_create);
  LOAD_MPV_RENDER_SYM(render_context_render);
  LOAD_MPV_RENDER_SYM(render_context_set_update_callback);
  LOAD_MPV_RENDER_SYM(render_context_update);
  LOAD_MPV_RENDER_SYM(render_context_free);
  LOAD_MPV_RENDER_SYM(render_context_report_swap);
#undef LOAD_MPV_RENDER_SYM
  loaded = true;
  return true;
}

// ─────────────── 注册 ───────────────

void PlayerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<PlayerPlugin>(registrar));
}

PlayerPlugin::PlayerPlugin(flutter::PluginRegistrarWindows* registrar)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.vbox.player/player",
          &flutter::StandardMethodCodec::GetInstance())),
      cloud_channel_(
          std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
              registrar->messenger(), "com.vbox.player/cloud_bridge",
              &flutter::StandardMethodCodec::GetInstance())),
      events_(std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.vbox.player/player/events",
          &flutter::StandardMethodCodec::GetInstance())) {
  // R-渲1：纹理注册表（open 建纹理、dispose 释放；纹理进程内唯一）。
  texture_registrar_ = registrar->texture_registrar();
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
  // 百度 bdstoken 原生 WebView2 桥（隐藏窗口承载，与播放器渲染互不相干）。
  // PluginRegistrarWindows 无 view() 访问器（旧 API 已移除），用 GetView()
  // 取隐式视图；多视图/无隐式视图场景回退 nullptr（桥内已容忍无父窗口）。
  flutter::FlutterView* flutter_view = registrar->GetView();
  baidu_bridge_ = std::make_unique<BaiduTokenBridge>(
      flutter_view != nullptr ? flutter_view->GetNativeWindow() : nullptr);
  // 取号链路原生日志 → player/events log 事件上抛（Dart ChannelPlayer 转
  // AppLog）：固定版加载 / COM / 环境 / 导航 / 脚本每一阶段的成败都有留痕，
  // 满足「有错误就打印错误日志」的排查诉求。
  baidu_bridge_->SetLogCallback(
      [this](const std::string& level, const std::string& message) {
        EmitLog(level, "[baidu] " + message);
      });
  cloud_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleCloudMethodCall(call, std::move(result));
      });
  stream_handler_ = std::make_unique<StreamHandler>(this);
  events_->SetStreamHandler(std::move(stream_handler_));
}

PlayerPlugin::~PlayerPlugin() {
  ShutdownMpv();
  ClearSink();
}

// ─────────────── 云侧桥通道（baidu_token_bridge） ───────────────

void PlayerPlugin::HandleCloudMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "getBdstoken") {
    std::string cookie;
    if (call.arguments() != nullptr) {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args != nullptr) {
        const auto it = args->find(flutter::EncodableValue("cookie"));
        if (it != args->end() && std::holds_alternative<std::string>(it->second)) {
          cookie = std::get<std::string>(it->second);
        }
      }
    }
    // Reply 是 std::function（要求可拷贝），unique_ptr 是 move-only——先转
    // shared_ptr 再捕获，否则 std::function 构造报 C2338（copy constructible）。
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_result(
        std::move(result));
    baidu_bridge_->GetBdstoken(
        cookie,
        [result = std::move(shared_result)](const flutter::EncodableValue& value) {
          result->Success(value);
        });
    return;
  }
  if (call.method_name() == "getBdstokenWinHttp") {
    // WinHTTP（Schannel 系统栈）直取 gettemplatevariable——对齐 iOS 第 1 层
    // URLSession。同步调用（紧超时，见 FetchBdstokenViaWinHttp）。原生侧先
    // 三跳种 BAIDUID 指纹，cookie 出参为富集后的完整 Cookie 供 Dart 回写凭据。
    std::string cookie;
    if (call.arguments() != nullptr) {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args != nullptr) {
        const auto it = args->find(flutter::EncodableValue("cookie"));
        if (it != args->end() && std::holds_alternative<std::string>(it->second)) {
          cookie = std::get<std::string>(it->second);
        }
      }
    }
    std::string token;
    std::string enriched_cookie;
    std::string detail;
    const int errno_code = BaiduTokenBridge::FetchBdstokenViaWinHttp(
        cookie, &token, &enriched_cookie, &detail);
    flutter::EncodableMap out;
    out[flutter::EncodableValue("errno")] =
        flutter::EncodableValue(errno_code);
    out[flutter::EncodableValue("bdstoken")] = flutter::EncodableValue(token);
    out[flutter::EncodableValue("cookie")] =
        flutter::EncodableValue(enriched_cookie);
    out[flutter::EncodableValue("message")] = flutter::EncodableValue(detail);
    result->Success(flutter::EncodableValue(out));
    return;
  }
  result->NotImplemented();
}

// ─────────────── StreamHandler ───────────────

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
PlayerPlugin::StreamHandler::OnListenInternal(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  plugin_->SetSink(std::move(events));
  // 已有播放器时补发一次当前进度，避免 Dart 侧错过中间态（对齐 macOS 插件）。
  plugin_->EmitProgress();
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
PlayerPlugin::StreamHandler::OnCancelInternal(
    const flutter::EncodableValue* arguments) {
  plugin_->ClearSink();
  return nullptr;
}

void PlayerPlugin::SetSink(
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  sink_ =
      std::shared_ptr<flutter::EventSink<flutter::EncodableValue>>(sink.release());
}

void PlayerPlugin::ClearSink() {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  sink_.reset();
}

std::shared_ptr<flutter::EventSink<flutter::EncodableValue>>
PlayerPlugin::SinkSnapshot() {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  return sink_;
}

// ─────────────── 方法面 ───────────────

void PlayerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "open") {
    Open(call.arguments(), std::move(result));
  } else if (method == "play") {
    Play(std::move(result));
  } else if (method == "pause") {
    Pause(std::move(result));
  } else if (method == "seekTo") {
    SeekTo(call.arguments(), std::move(result));
  } else if (method == "setVolume") {
    SetVolume(call.arguments(), std::move(result));
  } else if (method == "setSpeed") {
    SetSpeed(call.arguments(), std::move(result));
  } else if (method == "dispose") {
    Dispose(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void PlayerPlugin::Open(
    const flutter::EncodableValue* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap* map = AsMap(args);
  if (map == nullptr) {
    result->Error("E_PARAM", "open 缺少参数");
    return;
  }
  const std::string url = GetString(*map, "url");
  if (url.empty()) {
    result->Error("E_INVALID_SOURCE", "无效的播放源");
    return;
  }
  // 只记录 host（播放直链常带签名参数，不入日志，避免泄漏凭据）。
  std::string host = url;
  const size_t scheme = host.find("://");
  if (scheme != std::string::npos) {
    host = host.substr(scheme + 3);
  }
  const size_t slash = host.find('/');
  if (slash != std::string::npos) {
    host = host.substr(0, slash);
  }
  EmitLog("info", "open 请求：host=" + host +
                      "，urlLength=" + std::to_string(url.size()));

  // 后端口径：本插件仅实现 libmpv（D6 桌面主后端）。
  const std::string backend = GetString(*map, "backend", "libmpv");
  if (backend != "libmpv") {
    result->Error("E_BACKEND_UNAVAILABLE",
                  "该插件仅实现 libmpv 后端，收到 backend=" + backend);
    return;
  }

  // D28：mpv-2.dll 随包分发；加载失败（文件缺失 / 依赖缺失 / 拦截）按
  // Load() 分类原因上报 E_BACKEND_UNAVAILABLE 由 Dart 侧处理。
  if (!api_.Load()) {
    result->Error("E_BACKEND_UNAVAILABLE", api_.load_error + "，libmpv 不可用");
    return;
  }

  // 复用句柄时先释放旧实例。
  ShutdownMpv();

  const bool is_live = GetBool(*map, "isLive", false);
  if (!InitializeMpv(is_live)) {
    result->Error("E_BACKEND_UNAVAILABLE", "libmpv 初始化失败");
    return;
  }

  // 自定义请求头 → http-header-fields 选项（open 后由 loadfile 生效）。
  const std::string headers = JoinHeaders(*map);
  if (!headers.empty()) {
    api_.set_option_string(mpv_, "http-header-fields", headers.c_str());
  }

  // loadfile（replace：单文件播放，与 macOS/Android 语义一致）。
  const char* load_args[] = {"loadfile", url.c_str(), "replace", nullptr};
  if (api_.command(mpv_, load_args) < 0) {
    ShutdownMpv();
    result->Error("E_OPEN", "loadfile 命令失败");
    return;
  }

  EmitState("opening");
  // R-渲1：把纹理句柄交回 Dart（`Texture(textureId:)` 承载画面）。
  // 无渲染输出面（render API 缺失）时返回空 map → Dart textureId=null → 深色占位。
  // 注意：纹理由渲染线程懒注册，此刻通常尚未就绪（texture_id_ == -1）。
  // 注册完成后经 `EmitTextureReady` 事件补发句柄，Dart 侧据此挂载纹理。
  const int64_t texture_id = texture_id_.load();
  flutter::EncodableMap payload;
  if (texture_id >= 0) {
    payload[flutter::EncodableValue("textureId")] =
        flutter::EncodableValue(texture_id);
  }
  result->Success(flutter::EncodableValue(payload));
}

void PlayerPlugin::Play(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (mpv_ != nullptr) {
    int flag = 0;  // pause=false
    api_.set_property(mpv_, "pause", MPV_FORMAT_FLAG, &flag);
  }
  result->Success();
}

void PlayerPlugin::Pause(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (mpv_ != nullptr) {
    int flag = 1;  // pause=true
    api_.set_property(mpv_, "pause", MPV_FORMAT_FLAG, &flag);
  }
  result->Success();
}

void PlayerPlugin::SeekTo(
    const flutter::EncodableValue* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (mpv_ == nullptr) {
    result->Success();
    return;
  }
  int64_t position_ms = 0;
  if (args != nullptr) {
    if (std::holds_alternative<int32_t>(*args)) {
      position_ms = std::get<int32_t>(*args);
    } else if (std::holds_alternative<int64_t>(*args)) {
      position_ms = std::get<int64_t>(*args);
    } else {
      result->Error("E_BAD_ARGUMENT", "seekTo 需毫秒整数");
      return;
    }
  }
  double seconds = static_cast<double>(position_ms) / 1000.0;
  api_.set_property(mpv_, "time-pos", MPV_FORMAT_DOUBLE, &seconds);
  result->Success();
}

void PlayerPlugin::SetVolume(
    const flutter::EncodableValue* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (args == nullptr || !std::holds_alternative<double>(*args)) {
    result->Error("E_BAD_ARGUMENT", "setVolume 需浮点数");
    return;
  }
  const double volume = std::get<double>(*args);
  if (mpv_ != nullptr) {
    const double clamped = (volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume);
    double mpv_volume = clamped * 100.0;  // mpv 音量域 0~100
    api_.set_property(mpv_, "volume", MPV_FORMAT_DOUBLE, &mpv_volume);
  }
  result->Success();
}

void PlayerPlugin::SetSpeed(
    const flutter::EncodableValue* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (args == nullptr || !std::holds_alternative<double>(*args)) {
    result->Error("E_BAD_ARGUMENT", "setSpeed 需浮点数");
    return;
  }
  const double speed = std::get<double>(*args);
  if (mpv_ != nullptr) {
    double clamped = (speed < 0.25) ? 0.25 : ((speed > 4.0) ? 4.0 : speed);
    api_.set_property(mpv_, "speed", MPV_FORMAT_DOUBLE, &clamped);
  }
  result->Success();
}

void PlayerPlugin::Dispose(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  ShutdownMpv();
  result->Success();
}

// ─────────────── libmpv 生命周期 ───────────────

namespace {

// 环境变量开关判定：已设置且值不为 0/false/no 即视为开（空串视为关）。
bool IsEnvFlagSet(const wchar_t* name) {
  wchar_t value[8]{};
  const DWORD n = ::GetEnvironmentVariableW(name, value, 8);
  if (n == 0) return false;
  if (n >= 8) return true;  // 缓冲不够长 → 值非空且较长，视为开
  return ::lstrcmpW(value, L"0") != 0 && ::lstrcmpiW(value, L"false") != 0 &&
         ::lstrcmpiW(value, L"no") != 0;
}

}  // namespace

bool PlayerPlugin::InitializeMpv(bool auto_play) {
  mpv_handle* handle = api_.create();
  if (handle == nullptr) {
    return false;
  }
  // R-渲1：有 render API 时走 `vo=libmpv`（mpv_render_context 前置），
  // 每帧 GPU 渲染为 BGRA 交 Flutter 纹理上屏；否则退回 `vo=null`（纯控制面）。
  // 注意：vo 属「初始化前生效」选项，必须早于 mpv_initialize 设置，
  // 否则默认 vo 会在 Windows 弹出独立 mpv 渲染窗口，破坏无窗口契约。
  //
  // 问题 2：`render_context_create` 函数指针非空只说明 dll 里带 render API，
  // 不代表离屏 GL 渲染真的可用（无显卡驱动 / OpenGL 1.1 软实现 / 远程桌面
  // 会话下 FBO 入口为空 → 渲染线程静默退出 → 有声音无画面）。
  // 预检结论只写日志、不作闸门：预检在平台线程、正式渲染在渲染线程，为避免
  // 预检误判导致本来能出画面却不出，仍让 mpv 真正尝试一次；真失败时渲染链
  // 有逐环日志，并自动回退到 SW 软渲染（见 RunRenderLoop）。
  const bool has_render_api = api_.render_context_create != nullptr;
  if (has_render_api) {
    std::string probe_detail;
    const bool probe_ok =
        ProbeGlCapability(&probe_detail, &prefer_software_render_);
    EmitLog(probe_ok ? "info" : "warn",
            "GL 能力预检（仅提示，不阻断）：" + probe_detail);
    // GL 路径逃生门（云电脑泛黄/花屏）：虚拟显卡上 GL 离屏回读可能产生
    // 通道级颜色错乱（glFinish 只能修复撕裂/叠影，修不了颜色错乱），且黑
    // 名单不可能覆盖所有云电脑 GPU 型号。设置环境变量
    // VBOX_FORCE_SW_RENDER=1 可强制全程软件渲染（SW 输出色彩已钉扎，见
    // CreateSwRenderContext），无需改代码即可在云电脑上恢复正确色彩。
    if (IsEnvFlagSet(L"VBOX_FORCE_SW_RENDER")) {
      prefer_software_render_ = true;
      EmitLog("info",
              "VBOX_FORCE_SW_RENDER=1：按用户要求强制使用软件渲染（SW）");
    }
  } else {
    EmitLog("warn", "mpv 未提供 render API（mpv-2.dll 过旧），回退 vo=null");
  }
  api_.set_option_string(handle, "vo", has_render_api ? "libmpv" : "null");
  if (has_render_api) {
    // 问题 5：桌面 render context 优先走 OpenGL(GPU) 后端，让 mpv 在 GPU 上跑
    // 完整色彩管线（primaries/gamma/HDR tone-mapping），对齐 iOS 的 GPU 路径，
    // 消除 SW 软渲染（仅 YUV→RGB 矩阵、缺色彩管理）导致的泛黄偏色。
    // 注：OpenGL 不可用时会自动退到 SW（见 RunRenderLoop），不受此选项影响。
    api_.set_option_string(handle, "gpu-api", "opengl");
  }
  // 画质档位（修复「有画面但画质发虚/不是原视频画质」）：mpv 默认
  // scale/cscale=bilinear 且未开 correct-downscaling，窗口化播放时 1080p
  // 视频缩小显示的缩放质量明显劣于 iOS AVPlayer（VideoToolbox 高质量缩放），
  // 用户实测表现为「所有资源画质都不对，iOS 无此现象」——与取链无关，纯属
  // 渲染档位。优先启用 mpv 官方高质量画像（ewa_lanczossharp 缩放 + sigmoid
  // 上采样 + 色彩管理），旧版 libmpv 无 `high-quality` 时回退 `gpu-hq`
  // （spline36 档）；再显式钉住缩小保真/上采样两项，画像未生效时也不退回
  // bilinear 默认。渲染 API 缺失（vo=null 纯控制面）时无需设置。
  // 注：macOS PlayerPlugin.swift 走同一 mpv 管线，后续可同步同参。
  // 实际生效的硬解档位（无 render API 时保持"无"），设置与初始化日志共用。
  std::string hwdec = "无";
  if (has_render_api) {
    const char* quality_profile = "high-quality";
    if (api_.set_option_string(handle, "profile", quality_profile) < 0) {
      quality_profile = "gpu-hq";
      if (api_.set_option_string(handle, "profile", quality_profile) < 0) {
        quality_profile = nullptr;
        EmitLog("warn", "mpv 高质量画像不可用（mpv-2.dll 过旧），按显式参数兜底");
      }
    }
    api_.set_option_string(handle, "correct-downscaling", "yes");
    api_.set_option_string(handle, "linear-downscaling", "no");
    api_.set_option_string(handle, "sigmoid-upscaling", "yes");
    if (quality_profile != nullptr) {
      EmitLog("info", std::string("mpv 画质画像：") + quality_profile);
    }
    // 硬解（3.1858 卡顿修复 + 3.1859 软解回退修正）：用户日志实测 4K HEVC
    // 60fps 10-bit 走纯 CPU 软解时伴随连续「Audio device underrun」与丢帧
    // （CPU 彻底过载）——「一卡一卡」的根因，故 GL 路径取 auto-copy
    // （D3D11VA 解码后拷回系统内存，零拷贝 interop 在离屏 WGL 上下文有
    // 兼容风险，不走）。
    // 但 SW 软渲染路径（虚拟显卡 / 远程桌面 / 仅 OpenGL 1.1，预检已识别
    // prefer_software_render_=true）下，D3D11VA 在多数虚拟化环境不可用，
    // hwdec=auto-copy 初始化 AVHWDeviceContext 失败，且 copy-back 帧与 SW
    // 渲染链路存在配合缺口——用户实测「Node 高码视频有声音无画面」。故按
    // 渲染后端分档：SW → hwdec=no（纯 CPU 软解，杜绝无画面）；GL →
    // auto-copy（硬解加速，保留 4K 卡顿修复）。必须在 mpv_initialize 前设置。
    // 硬解分档默认（3.1859）：SW → no（纯 CPU 软解）；GL → auto-copy。
    // VBOX_HWDEC=no|auto-copy|auto 环境变量可覆盖默认——4K 在弱 CPU 云电脑
    // 上软解过载（Audio device underrun 实测），可不动代码切 auto-copy 试
    // D3D11VA 硬解（设备不可用时 mpv 自动回退软解，行为等价默认档）。
    // 3.1890 卡顿修复：SW 档位不再一刀切 hwdec=no。auto-safe 允许硬解初始化
    // 失败时由 mpv 自动回退软解（虚拟显卡上 auto-copy 建 AVHWDeviceContext
    // 失败会退成 no，行为等价旧档，但设备可用时能拿到硬解，4K 软解过载大幅
    // 缓解）。真出「有声无画」可用 VBOX_HWDEC=no 就地回退，无需重编。
    hwdec = prefer_software_render_ ? "auto-safe" : "auto-copy";
    wchar_t hwdec_env[16] = {0};
    if (::GetEnvironmentVariableW(L"VBOX_HWDEC", hwdec_env, 16) > 0 &&
        hwdec_env[0] != L'\0') {
      if (::lstrcmpiW(hwdec_env, L"no") == 0) {
        hwdec = "no";
      } else if (::lstrcmpiW(hwdec_env, L"auto-copy") == 0) {
        hwdec = "auto-copy";
      } else if (::lstrcmpiW(hwdec_env, L"auto") == 0) {
        hwdec = "auto";
      } else if (::lstrcmpiW(hwdec_env, L"auto-safe") == 0) {
        hwdec = "auto-safe";
      }
      EmitLog("info", "VBOX_HWDEC=" + hwdec + "（环境变量覆盖硬解分档默认）");
    }
    api_.set_option_string(handle, "hwdec", hwdec.c_str());

    // ── 3.1890 卡顿修复：丢帧策略 + 软渲染减负 ──────────────────────
    // framedrop 默认 no：渲染追不上时 mpv 不丢帧而是"往后拖时间"，表现就是
    // 持续一卡一卡、音画渐行渐远。交给 vo 决定丢帧，同步仍以 audio 为准。
    api_.set_option_string(handle, "framedrop", "vo");
    // 解码线程数 0 = auto（按核数）：云电脑/弱 CPU 上限制过少会解码不过来。
    api_.set_option_string(handle, "vd-lavc-threads", "0");
    if (prefer_software_render_) {
      // SW 后端上 GPU 缩放器（ewa_lanczossharp 等）本就不生效，但 profile 带的
      // dither / deband 仍会在 CPU 上跑，纯增开销——软渲染档位显式关掉。
      api_.set_option_string(handle, "dither-depth", "no");
      api_.set_option_string(handle, "deband", "no");
    }
  }
  if (api_.initialize(handle) < 0) {
    api_.terminate_destroy(handle);
    EmitLog("error", "mpv_initialize 失败");
    return false;
  }
  mpv_ = handle;
  // mpv 内部日志上抛（对齐 iOS 排查详细度）：info 及以上经
  // MPV_EVENT_LOG_MESSAGE 转 EmitLog 交 Dart AppLog。
  if (api_.request_log_messages != nullptr) {
    api_.request_log_messages(mpv_, "info");
  }
  EmitLog("info", "mpv 初始化完成（vo=" +
                      std::string(has_render_api ? "libmpv" : "null") +
                      "，gpu-api=" +
                      std::string(has_render_api ? "opengl" : "无") +
                      "，hwdec=" + hwdec +
                      "）");

  // 直播流（isLive）open 后自动起播，对齐 Android ExoPlayer 行为；点播保持暂停待 play()。
  int pause = auto_play ? 0 : 1;
  api_.set_property(mpv_, "pause", MPV_FORMAT_FLAG, &pause);

  // 事件面：进度 / 状态由属性变更驱动。
  api_.observe_property(mpv_, 0, "time-pos", MPV_FORMAT_DOUBLE);
  api_.observe_property(mpv_, 0, "duration", MPV_FORMAT_DOUBLE);
  api_.observe_property(mpv_, 0, "pause", MPV_FORMAT_FLAG);
  api_.observe_property(mpv_, 0, "paused-for-cache", MPV_FORMAT_FLAG);
  api_.observe_property(mpv_, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE);

  // 渲染输出面（R-渲1）：建 render_context + 注册纹理 + 起渲染线程。
  // 先试 OpenGL，失败在渲染线程内自动回退 SW（见 RunRenderLoop）。
  if (has_render_api) {
    SetupRenderContext();
  }

  running_ = true;
  event_thread_ =
      std::make_unique<std::thread>(&PlayerPlugin::RunEventLoop, this);
  return true;
}

void PlayerPlugin::ShutdownMpv() {
  // 先停渲染线程：GL 上下文（WGL 线程亲和）与 render_context 均在渲染线程
  // 内创建/释放（RunRenderLoop 退出前 DestroyGlRenderContext 完成），此处 join
  // 等待其收尾，避免释放 mpv_ 时仍有渲染。
  if (render_thread_ != nullptr) {
    render_running_ = false;
    render_cv_.notify_all();
    render_thread_->join();
    render_thread_.reset();
  }
  // 兜底：渲染线程异常早退（未走到 DestroyGlRenderContext）时补释放。
  if (render_ctx_ != nullptr) {
    api_.render_context_set_update_callback(render_ctx_, nullptr, nullptr);
    api_.render_context_free(render_ctx_);
    render_ctx_ = nullptr;
  }
  UnregisterTexture();
  {
    // 竞态修复（0xC0000409 闪退根因）：引擎光栅线程经 CopyPixelBuffer 拿到
    // 帧槽后、OnPixelBufferReleased 归还前，该槽 buffer 绝不可释放。旧实现
    // 在 1s 有界等待超时后仍强制 clear 全部槽——引擎（云电脑负载下光栅线程
    // 可能长时间卡顿）稍后继续采样已释放内存 → STATUS_STACK_BUFFER_OVERRUN
    // fastfail（flutter_windows.dll 内确定性偏移，实测两次崩溃同址）。
    // 现改为：仅复位未锁定槽；锁定槽原样保留，交由引擎 release 回调在
    // OnPixelBufferReleased 中复位。buffer 内存一律不在此释放（待下次
    // PublishFrame swap 时自然回收），竞态窗口归零。渲染线程已 join 不会再
    // 产生新帧；此处只可能被引擎 release 回调唤醒，1s 超时兜底防死锁。
    std::unique_lock<std::mutex> lock(frame_mutex_);
    frame_cv_.wait_for(lock, std::chrono::milliseconds(1000), [this] {
      for (const FrameSlot& s : frame_slots_) {
        if (s.locked) {
          return false;
        }
      }
      return true;
    });
    for (FrameSlot& s : frame_slots_) {
      if (s.locked) {
        // 引擎仍持有：原样保留（含 buffer），等 release 回调归还时复位。
        continue;
      }
      s.width = 0;
      s.height = 0;
      s.seq = 0;
      s.locked = false;
    }
    frame_seq_ = 0;
  }
  last_video_width_ = 0;
  last_video_height_ = 0;
  // 渲染后端与软渲染缓冲随会话释放。
  render_backend_ = RenderBackend::none;
  // 渲染偏好随会话复位（下次 Open 由预检重新判定）。
  prefer_software_render_ = false;
  sw_frame_buffer_.clear();
  sw_frame_buffer_.shrink_to_fit();
  sw_frame_width_ = 0;
  sw_frame_height_ = 0;
  // 日志去重标记随会话复位，避免上一次失败导致本次不再上报关键日志。
  logged_first_frame_ = false;
  logged_render_failure_ = false;
  logged_frame_drop_ = false;

  if (event_thread_ != nullptr) {
    running_ = false;
    event_thread_->join();
    event_thread_.reset();
  }
  if (mpv_ != nullptr) {
    api_.terminate_destroy(mpv_);
    mpv_ = nullptr;
  }
  state_ = "idle";
}

// ─────────────── 渲染输出面（R-渲1）───────────────

namespace {

// 承载 WGL 上下文的隐藏窗口类名（预检与正式渲染共用，注册幂等）。
constexpr const wchar_t kGlWindowClass[] = L"VboxMpvGlHiddenWnd";

// 注册（幂等）隐藏窗口类并创建 1x1 窗口，返回窗口句柄并回填 HDC。
// 失败返回 nullptr（`wglCreateContext` 需要已设像素格式的 HDC）。
HWND CreateHiddenGlWindow(HDC* out_hdc) {
  static bool class_registered = false;
  HINSTANCE instance = ::GetModuleHandleW(nullptr);
  if (!class_registered) {
    WNDCLASSW wc{};
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = ::DefWindowProcW;
    wc.hInstance = instance;
    wc.lpszClassName = kGlWindowClass;
    if (::RegisterClassW(&wc) == 0 &&
        ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return nullptr;
    }
    class_registered = true;
  }
  HWND hwnd = ::CreateWindowExW(0, kGlWindowClass, L"", WS_OVERLAPPED, 0, 0, 1, 1,
                                nullptr, nullptr, instance, nullptr);
  if (hwnd == nullptr) {
    return nullptr;
  }
  HDC hdc = ::GetDC(hwnd);
  if (hdc == nullptr) {
    ::DestroyWindow(hwnd);
    return nullptr;
  }
  *out_hdc = hdc;
  return hwnd;
}

// 为 HDC 选择并设定 OpenGL 像素格式。
bool SetGlPixelFormat(HDC hdc) {
  PIXELFORMATDESCRIPTOR pfd{};
  pfd.nSize = sizeof(pfd);
  pfd.nVersion = 1;
  pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
  pfd.iPixelType = PFD_TYPE_RGBA;
  pfd.cColorBits = 32;
  pfd.cAlphaBits = 8;
  pfd.iLayerType = PFD_MAIN_PLANE;
  const int pf = ::ChoosePixelFormat(hdc, &pfd);
  if (pf == 0 || !::SetPixelFormat(hdc, pf, &pfd)) {
    return false;
  }
  return true;
}

}  // namespace

// 平台无关 GL 能力预检：建临时 WGL 上下文，读 GL 版本并检查 FBO 扩展入口。
//
// 为什么需要：`vo=libmpv` 属「初始化前生效」选项，一旦设为 libmpv 就不能回退；
// 而离屏渲染依赖 FBO（`glGenFramebuffers` 等经 wglGetProcAddress 解析）。在无
// 显卡驱动 / 仅 OpenGL 1.1 软件实现 / 远程桌面会话下这些入口恒为空指针，届时
// 渲染线程会静默退出——表现为「有声音、有进度、无画面」。预检可提前发现，
// 让 mpv 走 `vo=null`，避免用户面对无解释的黑屏。
bool PlayerPlugin::ProbeGlCapability(std::string* detail,
                                     bool* out_prefer_software) {
  HMODULE ogl = ::LoadLibraryW(L"opengl32.dll");
  if (ogl == nullptr) {
    if (detail != nullptr) *detail = "opengl32.dll 加载失败";
    return false;
  }

  HWND hwnd = nullptr;
  HDC hdc = nullptr;
  HGLRC glrc = nullptr;
  bool ok = false;
  do {
    hwnd = CreateHiddenGlWindow(&hdc);
    if (hwnd == nullptr) {
      if (detail != nullptr) *detail = "隐藏窗口创建失败";
      break;
    }
    if (!SetGlPixelFormat(hdc)) {
      if (detail != nullptr) *detail = "像素格式设置失败（无 OpenGL 像素格式）";
      break;
    }
    auto wgl_create_context = reinterpret_cast<HGLRC (*)(HDC)>(
        ::GetProcAddress(ogl, "wglCreateContext"));
    auto wgl_make_current = reinterpret_cast<BOOL (*)(HDC, HGLRC)>(
        ::GetProcAddress(ogl, "wglMakeCurrent"));
    auto wgl_delete_context = reinterpret_cast<BOOL (*)(HGLRC)>(
        ::GetProcAddress(ogl, "wglDeleteContext"));
    auto wgl_get_proc_address = reinterpret_cast<void* (*)(const char*)>(
        ::GetProcAddress(ogl, "wglGetProcAddress"));
    if (wgl_create_context == nullptr || wgl_make_current == nullptr ||
        wgl_delete_context == nullptr || wgl_get_proc_address == nullptr) {
      if (detail != nullptr) *detail = "WGL 入口解析失败";
      break;
    }
    glrc = wgl_create_context(hdc);
    if (glrc == nullptr) {
      if (detail != nullptr) *detail = "wglCreateContext 失败（无可用显卡驱动）";
      break;
    }
    if (!wgl_make_current(hdc, glrc)) {
      if (detail != nullptr) *detail = "wglMakeCurrent 失败";
      break;
    }
    // GL 版本（glGetString 属 GL 1.1 导出；GL_VERSION = 0x1F02）。
    auto gl_get_string = reinterpret_cast<const unsigned char* (*)(GlEnum)>(
        ::GetProcAddress(ogl, "glGetString"));
    std::string version = "未知";
    if (gl_get_string != nullptr) {
      const unsigned char* v = gl_get_string(0x1F02 /* GL_VERSION */);
      if (v != nullptr) version = reinterpret_cast<const char*>(v);
    }
    void* gen_framebuffers = wgl_get_proc_address("glGenFramebuffers");
    if (gen_framebuffers == nullptr) {
      // FBO 入口缺失（OpenGL 1.1 软实现 / 无显卡驱动）：GL 离屏渲染必然失败，
      // 标记走软件渲染——同时影响 RunRenderLoop 后端选择与 hwdec 分档
      // （SW 后端需 hwdec=no，否则 auto-copy 硬解初始化失败会导致无画面）。
      if (out_prefer_software != nullptr) {
        *out_prefer_software = true;
      }
      if (detail != nullptr) {
        *detail = "OpenGL " + version + "，FBO 入口不可用（需 OpenGL 2.0+）"
                  " → 改用软件渲染";
      }
      break;
    }
    // 渲染器 / 厂商（GL_RENDERER = 0x1F01，GL_VENDOR = 0x1F00）。
    std::string renderer = "未知";
    if (gl_get_string != nullptr) {
      const unsigned char* r = gl_get_string(0x1F01 /* GL_RENDERER */);
      if (r != nullptr) renderer = reinterpret_cast<const char*>(r);
    }
    // 虚拟显卡 / 软渲染黑名单：这些实现名义上支持 GL 2.0+（FBO 入口非空），
    // 但 glReadPixels 从 FBO 回读会产生撕裂、叠影、颜色错乱（云电脑 / 远程桌面 /
    // 无显卡驱动）。命中或处于远程桌面会话时，改走 libswscale 软渲染。
    const bool is_software_renderer =
        renderer.find("GDI Generic") != std::string::npos ||
        renderer.find("Microsoft Basic Render") != std::string::npos ||
        renderer.find("Microsoft GDI") != std::string::npos ||
        renderer.find("WARP") != std::string::npos ||
        renderer.find("llvmpipe") != std::string::npos ||
        renderer.find("softpipe") != std::string::npos ||
        renderer.find("SwiftShader") != std::string::npos ||
        renderer.find("VMware SVGA") != std::string::npos ||
        renderer.find("VirtualBox") != std::string::npos;
    // 远程桌面 / 云电脑会话（SM_REMOTESESSION != 0）。
    const bool is_remote_session = ::GetSystemMetrics(SM_REMOTESESSION) != 0;
    if (is_software_renderer || is_remote_session) {
      if (out_prefer_software != nullptr) {
        *out_prefer_software = true;
      }
      if (detail != nullptr) {
        *detail = "OpenGL " + version + "，渲染器=" + renderer +
                  (is_remote_session ? "，远程桌面会话" : "，软渲染实现") +
                  " → 改用软件渲染";
      }
      ok = false;
      break;
    }
    // 回读颜色自检（3.1856，云电脑偏色根因检测）：向 FBO 画已知纯色并回读
    // 比对 BGRA 字节序。虚拟化 GPU（GRID/Paravirtual 等真名不在黑名单的
    // 虚拟显卡）glReadPixels 可能输出通道交换/错乱的颜色——glFinish 修撕裂
    // 修不了颜色。黑名单只能枚举已知型号，实测才是确定性判据：回读字节
    // 与预期不符 → 该环境 GL 回读不可信 → 强制 SW（SW 色彩已钉扎）。
    // 双色校验（红+绿）同时排除「全 0 / 全 255」假阳性。
    do {
      auto gl_gen_textures = reinterpret_cast<void (*)(GlSizei, GlUint*)>(
          ::GetProcAddress(ogl, "glGenTextures"));
      auto gl_bind_texture = reinterpret_cast<void (*)(GlEnum, GlUint)>(
          ::GetProcAddress(ogl, "glBindTexture"));
      auto gl_tex_image_2d = reinterpret_cast<void (*)(
          GlEnum, GlInt, GlInt, GlSizei, GlSizei, GlInt, GlEnum, GlEnum,
          const void*)>(::GetProcAddress(ogl, "glTexImage2D"));
      auto gl_tex_parameter_i = reinterpret_cast<void (*)(GlEnum, GlEnum, GlInt)>(
          ::GetProcAddress(ogl, "glTexParameteri"));
      auto gl_clear_color = reinterpret_cast<void (*)(float, float, float, float)>(
          ::GetProcAddress(ogl, "glClearColor"));
      auto gl_clear = reinterpret_cast<void (*)(unsigned int)>(
          ::GetProcAddress(ogl, "glClear"));
      auto gl_read_pixels = reinterpret_cast<void (*)(
          GlInt, GlInt, GlSizei, GlSizei, GlEnum, GlEnum, void*)>(
          ::GetProcAddress(ogl, "glReadPixels"));
      auto gl_delete_textures =
          reinterpret_cast<void (*)(GlSizei, const GlUint*)>(
              ::GetProcAddress(ogl, "glDeleteTextures"));
      auto wgl_bind_framebuffer =
          reinterpret_cast<void (*)(GlEnum, GlUint)>(
              wgl_get_proc_address("glBindFramebuffer"));
      auto wgl_framebuffer_texture_2d =
          reinterpret_cast<void (*)(GlEnum, GlEnum, GlEnum, GlUint, GlInt)>(
              wgl_get_proc_address("glFramebufferTexture2D"));
      auto wgl_delete_framebuffers =
          reinterpret_cast<void (*)(GlSizei, const GlUint*)>(
              wgl_get_proc_address("glDeleteFramebuffers"));
      if (gl_gen_textures == nullptr || gl_bind_texture == nullptr ||
          gl_tex_image_2d == nullptr || gl_tex_parameter_i == nullptr ||
          gl_clear_color == nullptr || gl_clear == nullptr ||
          gl_read_pixels == nullptr || gl_delete_textures == nullptr ||
          wgl_bind_framebuffer == nullptr ||
          wgl_framebuffer_texture_2d == nullptr ||
          wgl_delete_framebuffers == nullptr) {
        // 入口不全 = GL 版本不足以支撑离屏 FBO 路径（CreateGlRenderContext
        // 同样会失败），按「GL 不可用」处理，标记走软件渲染（同 FBO 缺失路径，
        // 供 RunRenderLoop 后端选择与 hwdec 分档使用）。
        if (out_prefer_software != nullptr) {
          *out_prefer_software = true;
        }
        if (detail != nullptr) {
          *detail = "OpenGL " + version + "，渲染器=" + renderer +
                    "，回读自检入口不全 → 改用软件渲染";
        }
        ok = false;
        break;
      }
      constexpr int kProbe = 4;
      GlUint tex = 0;
      GlUint fbo = 0;
      unsigned char px[kProbe * kProbe * 4] = {};
      bool color_ok = true;
      gl_gen_textures(1, &tex);
      gl_bind_texture(kGlTexture2D, tex);
      gl_tex_parameter_i(kGlTexture2D, kGlTextureMinFilter, 0x2600 /*NEAREST*/);
      gl_tex_image_2d(kGlTexture2D, 0, kGlRgba8, kProbe, kProbe, 0, kGlRgba,
                      kGlUnsignedByte, nullptr);
      reinterpret_cast<void (*)(GlSizei, GlUint*)>(gen_framebuffers)(1, &fbo);
      wgl_bind_framebuffer(kGlFramebuffer, fbo);
      wgl_framebuffer_texture_2d(kGlFramebuffer, kGlColorAttachment0,
                                 kGlTexture2D, tex, 0);
      // 纯红 (1,0,0)：BGRA 字节序应为 B=0,G=0,R=255,A=255。
      gl_clear_color(1.0f, 0.0f, 0.0f, 1.0f);
      gl_clear(0x4000 /*GL_COLOR_BUFFER_BIT*/);
      gl_read_pixels(0, 0, kProbe, kProbe, kGlBgra, kGlUnsignedByte, px);
      for (int i = 0; i < kProbe * kProbe; ++i) {
        if (px[i * 4] != 0 || px[i * 4 + 1] != 0 || px[i * 4 + 2] != 255 ||
            px[i * 4 + 3] != 255) {
          color_ok = false;
          break;
        }
      }
      // 纯绿 (0,1,0)：BGRA 应为 B=0,G=255,R=0,A=255。
      if (color_ok) {
        gl_clear_color(0.0f, 1.0f, 0.0f, 1.0f);
        gl_clear(0x4000);
        gl_read_pixels(0, 0, kProbe, kProbe, kGlBgra, kGlUnsignedByte, px);
        for (int i = 0; i < kProbe * kProbe; ++i) {
          if (px[i * 4] != 0 || px[i * 4 + 1] != 255 || px[i * 4 + 2] != 0 ||
              px[i * 4 + 3] != 255) {
            color_ok = false;
            break;
          }
        }
      }
      wgl_bind_framebuffer(kGlFramebuffer, 0);
      wgl_delete_framebuffers(1, &fbo);
      gl_delete_textures(1, &tex);
      if (!color_ok) {
        if (out_prefer_software != nullptr) {
          *out_prefer_software = true;
        }
        if (detail != nullptr) {
          *detail = "OpenGL " + version + "，渲染器=" + renderer +
                    "，回读颜色自检失败（通道错乱/虚拟显卡）→ 改用软件渲染";
        }
        ok = false;
        break;
      }
      if (detail != nullptr) {
        *detail = "OpenGL " + version + "，渲染器=" + renderer +
                  "，FBO 回读自检通过";
      }
      ok = true;
    } while (false);
  } while (false);

  if (glrc != nullptr) {
    auto wgl_make_current = reinterpret_cast<BOOL (*)(HDC, HGLRC)>(
        ::GetProcAddress(ogl, "wglMakeCurrent"));
    auto wgl_delete_context = reinterpret_cast<BOOL (*)(HGLRC)>(
        ::GetProcAddress(ogl, "wglDeleteContext"));
    if (wgl_make_current != nullptr) wgl_make_current(nullptr, nullptr);
    if (wgl_delete_context != nullptr) wgl_delete_context(glrc);
  }
  if (hdc != nullptr && hwnd != nullptr) {
    ::ReleaseDC(hwnd, hdc);
  }
  if (hwnd != nullptr) {
    ::DestroyWindow(hwnd);
  }
  ::FreeLibrary(ogl);
  return ok;
}

void PlayerPlugin::EmitLog(const std::string& level,
                           const std::string& message) {
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink =
      SinkSnapshot();
  if (sink == nullptr) {
    return;
  }
  sink->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue(std::string("type")),
       flutter::EncodableValue(std::string("log"))},
      {flutter::EncodableValue(std::string("level")),
       flutter::EncodableValue(level)},
      {flutter::EncodableValue(std::string("message")),
       flutter::EncodableValue(message)},
  }));
}

bool PlayerPlugin::SetupRenderContext() {
  if (api_.render_context_create == nullptr || mpv_ == nullptr) {
    return false;
  }
  // 问题 5：桌面 render context 改走 OpenGL(GPU) 后端（kRenderApiGl），对齐
  // iOS 的 GPU 渲染路径，让 mpv 在 GPU 上执行完整色彩管线（primaries/gamma/
  // HDR tone-mapping），消除 SW 软渲染（仅 YUV→RGB 矩阵）导致的泛黄偏色。
  // WGL 上下文具线程亲和性：创建/渲染/销毁全部收敛到渲染线程（RunRenderLoop
  // → CreateGlRenderContext / DestroyGlRenderContext）。
  render_running_ = true;
  render_thread_ =
      std::make_unique<std::thread>(&PlayerPlugin::RunRenderLoop, this);
  return true;
}

// 渲染线程内：建隐藏窗口 + WGL 上下文 + mpv OpenGL render_context。
bool PlayerPlugin::CreateGlRenderContext() {
  if (api_.render_context_create == nullptr || mpv_ == nullptr) {
    EmitLog("error", "创建 GL 渲染上下文失败：render API 或 mpv 句柄不可用");
    return false;
  }
  // 1) opengl32.dll：GL 1.1 入口 + WGL（系统组件，恒存在）。
  opengl32_ = ::LoadLibraryW(L"opengl32.dll");
  if (opengl32_ == nullptr) {
    EmitLog("error", "创建 GL 渲染上下文失败：opengl32.dll 加载失败");
    return false;
  }
  wgl_.create_context = reinterpret_cast<decltype(wgl_.create_context)>(
      ::GetProcAddress(opengl32_, "wglCreateContext"));
  wgl_.make_current = reinterpret_cast<decltype(wgl_.make_current)>(
      ::GetProcAddress(opengl32_, "wglMakeCurrent"));
  wgl_.delete_context = reinterpret_cast<decltype(wgl_.delete_context)>(
      ::GetProcAddress(opengl32_, "wglDeleteContext"));
  wgl_.get_proc_address = reinterpret_cast<decltype(wgl_.get_proc_address)>(
      ::GetProcAddress(opengl32_, "wglGetProcAddress"));
  if (wgl_.create_context == nullptr || wgl_.make_current == nullptr ||
      wgl_.delete_context == nullptr || wgl_.get_proc_address == nullptr) {
    EmitLog("error", "创建 GL 渲染上下文失败：WGL 入口解析失败");
    return false;
  }

  // 2) 隐藏窗口 + 像素格式（wglCreateContext 需已设像素格式的 HDC）。
  render_hwnd_ = CreateHiddenGlWindow(&render_hdc_);
  if (render_hwnd_ == nullptr) {
    EmitLog("error", "创建 GL 渲染上下文失败：隐藏窗口或 HDC 创建失败");
    return false;
  }
  if (!SetGlPixelFormat(render_hdc_)) {
    EmitLog("error", "创建 GL 渲染上下文失败：像素格式设置失败");
    return false;
  }

  // 3) WGL 上下文并置为当前（仅本渲染线程调用，满足线程亲和）。
  render_glrc_ = wgl_.create_context(render_hdc_);
  if (render_glrc_ == nullptr) {
    EmitLog("error", "创建 GL 渲染上下文失败：wglCreateContext 返回空");
    return false;
  }
  if (!wgl_.make_current(render_hdc_, render_glrc_)) {
    EmitLog("error", "创建 GL 渲染上下文失败：wglMakeCurrent 失败");
    return false;
  }

  // 4) 解析 GL 入口（须在当前上下文绑定后）。
  if (!LoadGlSymbols()) {
    EmitLog("error", "创建 GL 渲染上下文失败：GL 入口解析不全（FBO 需要 OpenGL 2.0+）");
    return false;
  }

  // 5) mpv render_context（OpenGL 后端）+ 高级控制（HDR/色彩管理，对齐 iOS）。
  mpv_opengl_init_params gl_init{};
  gl_init.get_proc_address = [](void* ctx, const char* name) -> void* {
    return static_cast<PlayerPlugin*>(ctx)->wgl_.get_proc_address(name);
  };
  gl_init.get_proc_address_ctx = this;
  int advanced_control = 1;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(kRenderApiGl)},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
      {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced_control},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  mpv_render_context* ctx = nullptr;
  const int rc = api_.render_context_create(&ctx, mpv_, params);
  if (rc < 0 || ctx == nullptr) {
    // 无纹理输出：Dart 侧深色占位，控制面（播放/进度）不受影响。
    const char* detail = api_.error_string != nullptr ? api_.error_string(rc) : nullptr;
    EmitLog("error",
            "mpv_render_context_create 失败（" +
                std::string(detail != nullptr ? detail : "未知原因") +
                "），无视频输出");
    return false;
  }
  render_ctx_ = ctx;
  render_backend_ = RenderBackend::opengl;
  // GL 路径色彩钉扎（3.1858 修正，与 SW 路径同口径）：primaries 钉 bt.709
  // （SDR 恒等、HDR 收敛到 SDR 显示），**TRC 改钉 bt.1886**——3.1856 曾钉
  // srgb，但视频标准 gamma=bt.1886(≈2.4) 转 sRGB(≈2.2) 会整体提亮中间调，
  // 恰是用户实测「灰蒙蒙/低对比」的经典症状；iOS mpv 直通 Metal 用的就是
  // 默认 bt.1886 原样输出（无 sRGB 转换），对齐 iOS 即对齐 bt.1886。
  // tone-mapping 保留（仅 HDR→SDR 时生效，SDR 不受影响）；旧版 mpv-2.dll
  // 不识别时选项被忽略，行为不变。
  api_.set_option_string(mpv_, "target-prim", "bt.709");
  api_.set_option_string(mpv_, "target-trc", "bt.1886");
  api_.set_option_string(mpv_, "tone-mapping", "bt.2390");
  api_.render_context_set_update_callback(render_ctx_, &PlayerPlugin::OnRenderUpdate,
                                          this);
  RegisterTexture();
  EmitLog("info", "mpv OpenGL render context 创建成功，纹理输出已就绪");
  return true;
}

// 渲染线程内：以 "sw" API 建 render context（libswscale 软渲染，无需 GL）。
//
// 用途（问题 2 兜底）：目标机无显卡驱动 / 处于远程桌面会话 / 仅有 OpenGL 1.1
// 时，OpenGL 离屏路径必然建不起来，此时若直接放弃就会「有声音无画面」。SW
// 后端不依赖 GPU，可保证画面仍能上屏；代价是无色彩管理（可能泛黄偏色）。
bool PlayerPlugin::CreateSwRenderContext() {
  if (api_.render_context_create == nullptr || mpv_ == nullptr) {
    return false;
  }
  // SW（libswscale）路径色彩修正：旧的 target-prim/target-trc/tone-mapping
  // 属 GPU 项，libswscale 软转换不识别（前注已自白，实测未生效）。改用直接
  // 作用于 libswscale 的 colormatrix 系列。4K 视频 YUV→RGB 默认矩阵应为
  // bt.709；range 保持 auto（缺元数据时回退有限范围）。逐项记录
  // set_option_string 返回值（<0 = mpv-2.dll 未识别该选项，即未生效），从
  // 日志即可判断设置是否被接受，而非盲改。
  const int cm = api_.set_option_string(mpv_, "colormatrix", "bt.709");
  const int cmp = api_.set_option_string(mpv_, "colormatrix-primaries", "bt.709");
  const int cmg = api_.set_option_string(mpv_, "colormatrix-gamma", "bt.1886");
  EmitLog("info",
          "SW 色彩矩阵设置结果：colormatrix=" + std::to_string(cm) +
              "，colormatrix-primaries=" + std::to_string(cmp) +
              "，colormatrix-gamma=" + std::to_string(cmg) +
              "（<0 = mpv 未识别，视为未生效）");
  int advanced_control = 1;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(kRenderApiSw)},
      {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced_control},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  mpv_render_context* ctx = nullptr;
  const int rc = api_.render_context_create(&ctx, mpv_, params);
  if (rc < 0 || ctx == nullptr) {
    const char* detail =
        api_.error_string != nullptr ? api_.error_string(rc) : nullptr;
    EmitLog("error",
            "mpv 软件渲染上下文创建失败（" +
                std::string(detail != nullptr ? detail : "未知原因") +
                "），无视频输出");
    return false;
  }
  render_ctx_ = ctx;
  render_backend_ = RenderBackend::software;
  api_.render_context_set_update_callback(render_ctx_, &PlayerPlugin::OnRenderUpdate,
                                          this);
  RegisterTexture();
  EmitLog("info", "mpv 软件渲染（SW）已就绪，视频将由 CPU 渲染上屏（色彩表现不如 GPU 路径）");
  return true;
}

// 渲染线程内：释放 render_context 与 GL 资源（保持 WGL 上下文当前）。
// 两个后端共用：software 后端只有 render_ctx_，GL 资源为空时各守卫直接跳过。
void PlayerPlugin::DestroyGlRenderContext() {
  // mpv OpenGL 后端要求释放 render_context 时 GL 上下文仍为当前。
  if (render_ctx_ != nullptr) {
    api_.render_context_set_update_callback(render_ctx_, nullptr, nullptr);
    api_.render_context_free(render_ctx_);
    render_ctx_ = nullptr;
  }
  render_backend_ = RenderBackend::none;
  if (render_fbo_ != 0 && gl_.delete_framebuffers != nullptr) {
    gl_.delete_framebuffers(1, &render_fbo_);
  }
  render_fbo_ = 0;
  if (render_tex_ != 0 && gl_.delete_textures != nullptr) {
    gl_.delete_textures(1, &render_tex_);
  }
  render_tex_ = 0;
  fbo_width_ = 0;
  fbo_height_ = 0;
  if (render_glrc_ != nullptr && wgl_.delete_context != nullptr) {
    wgl_.make_current(nullptr, nullptr);
    wgl_.delete_context(render_glrc_);
    render_glrc_ = nullptr;
  }
  if (render_hdc_ != nullptr && render_hwnd_ != nullptr) {
    ::ReleaseDC(render_hwnd_, render_hdc_);
    render_hdc_ = nullptr;
  }
  if (render_hwnd_ != nullptr) {
    ::DestroyWindow(render_hwnd_);
    render_hwnd_ = nullptr;
  }
  if (opengl32_ != nullptr) {
    ::FreeLibrary(opengl32_);
    opengl32_ = nullptr;
  }
}

// 渲染线程内：解析 GL 入口（GL 1.1 走 opengl32 导出；FBO 扩展走 wglGetProcAddress）。
bool PlayerPlugin::LoadGlSymbols() {
  gl_.gen_textures = reinterpret_cast<decltype(gl_.gen_textures)>(
      ::GetProcAddress(opengl32_, "glGenTextures"));
  gl_.delete_textures = reinterpret_cast<decltype(gl_.delete_textures)>(
      ::GetProcAddress(opengl32_, "glDeleteTextures"));
  gl_.bind_texture = reinterpret_cast<decltype(gl_.bind_texture)>(
      ::GetProcAddress(opengl32_, "glBindTexture"));
  gl_.tex_image_2d = reinterpret_cast<decltype(gl_.tex_image_2d)>(
      ::GetProcAddress(opengl32_, "glTexImage2D"));
  gl_.tex_parameter_i = reinterpret_cast<decltype(gl_.tex_parameter_i)>(
      ::GetProcAddress(opengl32_, "glTexParameteri"));
  gl_.pixel_store_i = reinterpret_cast<decltype(gl_.pixel_store_i)>(
      ::GetProcAddress(opengl32_, "glPixelStorei"));
  gl_.viewport = reinterpret_cast<decltype(gl_.viewport)>(
      ::GetProcAddress(opengl32_, "glViewport"));
  gl_.read_pixels = reinterpret_cast<decltype(gl_.read_pixels)>(
      ::GetProcAddress(opengl32_, "glReadPixels"));
  gl_.finish = reinterpret_cast<decltype(gl_.finish)>(
      ::GetProcAddress(opengl32_, "glFinish"));
  // FBO 属扩展入口（ARB_framebuffer_object / GL 3.0），须经 wglGetProcAddress。
  gl_.gen_framebuffers = reinterpret_cast<decltype(gl_.gen_framebuffers)>(
      wgl_.get_proc_address("glGenFramebuffers"));
  gl_.delete_framebuffers = reinterpret_cast<decltype(gl_.delete_framebuffers)>(
      wgl_.get_proc_address("glDeleteFramebuffers"));
  gl_.bind_framebuffer = reinterpret_cast<decltype(gl_.bind_framebuffer)>(
      wgl_.get_proc_address("glBindFramebuffer"));
  gl_.framebuffer_texture_2d =
      reinterpret_cast<decltype(gl_.framebuffer_texture_2d)>(
          wgl_.get_proc_address("glFramebufferTexture2D"));
  gl_.check_framebuffer_status =
      reinterpret_cast<decltype(gl_.check_framebuffer_status)>(
          wgl_.get_proc_address("glCheckFramebufferStatus"));
  // 逐项登记缺失入口，便于区分「GL 1.1 基础入口缺失」与「FBO 扩展缺失」
  //（后者几乎总是显卡驱动缺失 / 远程桌面会话 / OpenGL 1.1 软实现）。
  std::string missing;
  auto note_missing = [&missing](const char* name, bool present) {
    if (!present) {
      if (!missing.empty()) missing += ", ";
      missing += name;
    }
  };
  note_missing("glGenTextures", gl_.gen_textures != nullptr);
  note_missing("glDeleteTextures", gl_.delete_textures != nullptr);
  note_missing("glBindTexture", gl_.bind_texture != nullptr);
  note_missing("glTexImage2D", gl_.tex_image_2d != nullptr);
  note_missing("glTexParameteri", gl_.tex_parameter_i != nullptr);
  note_missing("glPixelStorei", gl_.pixel_store_i != nullptr);
  note_missing("glViewport", gl_.viewport != nullptr);
  note_missing("glReadPixels", gl_.read_pixels != nullptr);
  note_missing("glFinish", gl_.finish != nullptr);
  note_missing("glGenFramebuffers", gl_.gen_framebuffers != nullptr);
  note_missing("glDeleteFramebuffers", gl_.delete_framebuffers != nullptr);
  note_missing("glBindFramebuffer", gl_.bind_framebuffer != nullptr);
  note_missing("glFramebufferTexture2D", gl_.framebuffer_texture_2d != nullptr);
  note_missing("glCheckFramebufferStatus",
               gl_.check_framebuffer_status != nullptr);
  const bool complete = missing.empty();
  if (complete) {
    EmitLog("debug", "GL 入口解析完成（GL 1.1 + FBO 扩展齐全）");
  } else {
    EmitLog("error", "GL 入口缺失：" + missing);
  }
  return complete;
}

// 渲染线程内：按视频尺寸（懒）建/复用离屏 FBO + 颜色纹理。
bool PlayerPlugin::EnsureFbo(int width, int height) {
  if (width <= 0 || height <= 0) {
    return false;
  }
  if (render_fbo_ != 0 && render_tex_ != 0 && width == fbo_width_ &&
      height == fbo_height_) {
    return true;
  }
  // 尺寸变化：重建纹理 + FBO。
  if (render_fbo_ != 0) {
    gl_.delete_framebuffers(1, &render_fbo_);
    render_fbo_ = 0;
  }
  if (render_tex_ != 0) {
    gl_.delete_textures(1, &render_tex_);
    render_tex_ = 0;
  }
  gl_.gen_textures(1, &render_tex_);
  gl_.bind_texture(kGlTexture2D, render_tex_);
  gl_.tex_image_2d(kGlTexture2D, 0, kGlRgba8, width, height, 0, kGlRgba,
                   kGlUnsignedByte, nullptr);
  gl_.tex_parameter_i(kGlTexture2D, kGlTextureMinFilter, kGlLinear);
  gl_.tex_parameter_i(kGlTexture2D, kGlTextureMagFilter, kGlLinear);
  gl_.bind_texture(kGlTexture2D, 0);

  gl_.gen_framebuffers(1, &render_fbo_);
  gl_.bind_framebuffer(kGlFramebuffer, render_fbo_);
  gl_.framebuffer_texture_2d(kGlFramebuffer, kGlColorAttachment0, kGlTexture2D,
                             render_tex_, 0);
  const GlEnum status = gl_.check_framebuffer_status(kGlFramebuffer);
  gl_.bind_framebuffer(kGlFramebuffer, 0);
  if (status != kGlFramebufferComplete) {
    return false;
  }
  fbo_width_ = width;
  fbo_height_ = height;
  return true;
}

void PlayerPlugin::RegisterTexture() {
  if (texture_registrar_ == nullptr || texture_ != nullptr) {
    return;
  }
  texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
      [this](size_t width, size_t height) -> const FlutterDesktopPixelBuffer* {
        return CopyPixelBuffer(width, height);
      }));
  const int64_t texture_id = texture_registrar_->RegisterTexture(texture_.get());
  texture_id_.store(texture_id);
  // 渲染线程在 Open() 返回后才注册纹理 → 平台线程已提前返回空 payload。
  // 补发事件，让 Dart 侧挂载 `Texture(textureId:)`（否则无画面）。
  if (texture_id >= 0) {
    EmitTextureReady(texture_id);
  }
}

void PlayerPlugin::UnregisterTexture() {
  const int64_t texture_id = texture_id_.exchange(-1);
  if (texture_registrar_ != nullptr && texture_id >= 0) {
    texture_registrar_->UnregisterTexture(texture_id);
  }
  texture_.reset();
}

void PlayerPlugin::OnRenderUpdate(void* callback_ctx) {
  auto* self = static_cast<PlayerPlugin*>(callback_ctx);
  if (self == nullptr) {
    return;
  }
  self->render_requested_ = true;
  self->render_cv_.notify_one();
}

void PlayerPlugin::RunRenderLoop() {
  // 渲染线程内建 GL 上下文 + render_context（WGL 线程亲和）。
  if (prefer_software_render_) {
    // 预检已识别软渲染 OpenGL / 远程桌面会话：跳过 OpenGL 离屏路径，直接用
    // libswscale 软渲染，避免虚拟显卡 glReadPixels 回读产生的花屏/叠影。
    EmitLog("warn",
            "检测到软渲染 OpenGL 或远程桌面会话，直接使用 mpv 软件渲染（SW）");
    if (!CreateSwRenderContext()) {
      logged_render_failure_ = true;
      EmitError("当前设备无法建立视频输出（软件渲染失败），画面暂不可用，音频正常",
                false);
      return;
    }
  } else if (!CreateGlRenderContext()) {
    // 问题 2 兜底：OpenGL 离屏渲染不可用（无显卡驱动 / 远程桌面 / 仅 GL 1.1）
    // → 不再直接放弃，改走 libswscale 软渲染，保证仍有画面。失败原因已由
    // CreateGlRenderContext 逐环上报，此处仅清理半初始化资源再切换后端。
    DestroyGlRenderContext();
    EmitLog("warn", "OpenGL 视频输出不可用，回退 mpv 软件渲染（SW）");
    if (!CreateSwRenderContext()) {
      logged_render_failure_ = true;
      EmitError("当前设备无法建立视频输出（OpenGL 与软件渲染均失败），画面暂不可用，音频正常",
                false);
      DestroyGlRenderContext();
      return;
    }
  }
  while (render_running_.load()) {
    {
      std::unique_lock<std::mutex> lock(render_mutex_);
      render_cv_.wait_for(lock, std::chrono::milliseconds(100), [this] {
        return render_requested_.load() || !render_running_.load();
      });
      if (!render_running_.load()) {
        break;
      }
      render_requested_ = false;
    }
    if (render_ctx_ == nullptr) {
      continue;
    }
    // 恢复拉取式渲染：每 100ms 无条件渲染一帧（旧版行为）。3.1859 引入的
    // FRAME 闸门（仅 kRenderUpdateFrame 时渲染）是黑屏回归点：首帧在 VO
    // reconfig 时渲染消耗 FRAME 标志后，慢解码/软解过载下后续真实帧的 FRAME
    // 通知不再可靠置位 → 持续黑屏。render_context_update 仍需调用以驱动内部
    // 更新，但其返回值不再作为渲染门槛；真实帧解出前由 ResolveVideoSize
    // （尺寸未就绪即 return）兜住，不会渲出空帧。
    api_.render_context_update(render_ctx_);
    RenderFrame();
  }
  // 渲染线程内释放（保持 GL 上下文当前，满足 mpv OpenGL 后端释放契约）。
  DestroyGlRenderContext();
}

bool PlayerPlugin::ResolveVideoSize(int* width, int* height) {
  // 视频目标尺寸：优先 coded 尺寸（width/height），回退 display 尺寸。
  int64_t w = 0;
  int64_t h = 0;
  if (!GetInt64Property("width", &w) || w <= 0 ||
      !GetInt64Property("height", &h) || h <= 0) {
    if (!GetInt64Property("dwidth", &w) || w <= 0 ||
        !GetInt64Property("dheight", &h) || h <= 0) {
      return false;  // 尚未解出视频轨（纯音频 / 加载中）。
    }
  }
  *width = static_cast<int>(w);
  *height = static_cast<int>(h);
  return true;
}

namespace {

// 首帧像素转储（默认开启，VBOX_DUMP_FRAME=0/false/no/off 时关闭）：把 BGRA
// 缓冲写成 24 位 BMP（自底向上行序）。返回落盘路径；失败返回空串。GL 与 SW
// 后端的输出在此点均为 BGRA 顶行在上，同一口径。偏色定位后应改回默认关闭。
std::string DumpFirstFrameToBmp(const std::vector<uint8_t>& bgra, int width,
                                int height, bool software_backend) {
  char enabled[8] = {0};
  const DWORD env_len =
      ::GetEnvironmentVariableA("VBOX_DUMP_FRAME", enabled,
                                static_cast<DWORD>(sizeof(enabled)));
  // 默认开启（偏色排查用）：未设置环境变量即转储；仅显式设置为 0/false/no/off
  // 时关闭。定位修复后应改回默认关闭（见 AGENTS.md 待办）。
  if (env_len > 0) {
    const std::string opt(enabled);
    if (opt == "0" || opt == "false" || opt == "no" || opt == "off") {
      return "";
    }
  }
  if (width <= 0 || height <= 0 ||
      bgra.size() < static_cast<size_t>(width) * static_cast<size_t>(height) * 4) {
    return "";
  }
  char temp_dir[MAX_PATH] = {0};
  const DWORD len = ::GetTempPathA(MAX_PATH, temp_dir);
  if (len == 0 || len >= MAX_PATH - 64) {
    return "";
  }
  const std::string path = std::string(temp_dir) + "vbox_frame_" +
                           std::to_string(width) + "x" + std::to_string(height) +
                           (software_backend ? "_sw.bmp" : "_gl.bmp");
  const size_t row_bytes = ((static_cast<size_t>(width) * 3 + 3) / 4) * 4;
  const size_t image_bytes = row_bytes * static_cast<size_t>(height);
  BITMAPFILEHEADER file_hdr{};
  file_hdr.bfType = 0x4D42;  // 'BM'
  file_hdr.bfSize = static_cast<DWORD>(sizeof(file_hdr) +
                                       sizeof(BITMAPINFOHEADER) + image_bytes);
  file_hdr.bfOffBits =
      static_cast<DWORD>(sizeof(file_hdr) + sizeof(BITMAPINFOHEADER));
  BITMAPINFOHEADER info_hdr{};
  info_hdr.biSize = sizeof(info_hdr);
  info_hdr.biWidth = width;
  info_hdr.biHeight = height;  // 正值 = 自底向上
  info_hdr.biPlanes = 1;
  info_hdr.biBitCount = 24;
  info_hdr.biCompression = BI_RGB;
  info_hdr.biSizeImage = static_cast<DWORD>(image_bytes);
  info_hdr.biXPelsPerMeter = 2835;
  info_hdr.biYPelsPerMeter = 2835;
  std::vector<uint8_t> pixels(image_bytes, 0);
  for (int y = 0; y < height; ++y) {
    const uint8_t* src =
        bgra.data() + static_cast<size_t>(y) * static_cast<size_t>(width) * 4;
    uint8_t* dst = pixels.data() +
                   static_cast<size_t>(height - 1 - y) * row_bytes;
    for (int x = 0; x < width; ++x) {
      dst[x * 3 + 0] = src[x * 4 + 0];  // B
      dst[x * 3 + 1] = src[x * 4 + 1];  // G
      dst[x * 3 + 2] = src[x * 4 + 2];  // R
    }
  }
  FILE* f = nullptr;
  if (fopen_s(&f, path.c_str(), "wb") != 0 || f == nullptr) {
    return "";
  }
  fwrite(&file_hdr, sizeof(file_hdr), 1, f);
  fwrite(&info_hdr, sizeof(info_hdr), 1, f);
  fwrite(pixels.data(), 1, pixels.size(), f);
  fclose(f);
  return path;
}

}  // namespace

// 两个渲染后端共用的上屏尾段：丢帧判定 → 交 Flutter 纹理 → 首帧日志 → 尺寸
// 上报。缓冲尺寸（渲染目标，可能为显示尺寸）与视频原始尺寸（纵横比上报）
// 解耦：按显示尺寸渲染时二者不同。
void PlayerPlugin::PublishFrame(std::vector<uint8_t>& source, int width,
                                int height, int video_width, int video_height) {
  // 偏色排查逃生门（默认开启，VBOX_DUMP_FRAME=0 关闭）：首个「非黑」帧经此
  // 汇聚点落盘为 24 位 BMP（%TEMP%\vbox_frame_宽x高_后端.bmp）。像素级区分
  // 偏色责任方：BMP 颜色正常而屏幕偏色 → 显示器/系统；BMP 本身偏色 → mpv
  // 渲染管线（SW 软转换色彩弱）。GL / SW 两后端共用本函数，转储覆盖全路径。
  // 本帧判定标志：首个「非黑」帧（触发首帧诊断/转储/上屏日志）。
  bool first_non_black_frame = false;
  constexpr int kDiagFrameCount = 10;
  if (!source.empty()) {
    // 前 10 帧每帧都做像素统计：暴露「从黑到亮」过渡（首帧空→后续有色 = 帧
    // 上屏时序问题）还是「永远黑」（渲染管线始终未产出真实像素）。旧逻辑只
    // 在首帧打，且首帧恰是 pre-decode 空帧（SW 缓冲 0 初始化、mpv 未写入），
    // 造成 BMP/统计全拍假黑帧、误判为渲染管线坏，现改为逐帧留痕到有黑为止。
    if (frame_publish_count_ < kDiagFrameCount) {
      size_t non_black = 0;
      uint64_t luma_sum = 0;
      const size_t pixels = source.size() / 4;
      for (size_t i = 0; i < pixels; ++i) {
        const unsigned r = source[i * 4 + 2];
        const unsigned g = source[i * 4 + 1];
        const unsigned b = source[i * 4];
        const unsigned luma = (r * 299 + g * 587 + b * 114) >> 10;
        if (luma >= 16) ++non_black;
        luma_sum += luma;
      }
      EmitLog("info",
              "帧#" + std::to_string(frame_publish_count_ + 1) +
                  " 像素统计：非黑占比=" +
                  std::to_string(pixels > 0 ? non_black * 100 / pixels : 0) +
                  "%，平均亮度=" +
                  std::to_string(pixels > 0 ? luma_sum / pixels : 0) + "/255");
    }
    ++frame_publish_count_;

    if (!logged_first_frame_) {
      const size_t scan = std::min<size_t>(source.size() / 4, 4096);
      bool has_content = false;
      for (size_t i = 0; i < scan; ++i) {
        if (source[i * 4] + source[i * 4 + 1] + source[i * 4 + 2] > 48) {
          has_content = true;
          break;
        }
      }
      if (has_content) {
        first_non_black_frame = true;
        logged_first_frame_ = true;
        // 首个非黑帧才可靠的色彩参数（video-params 就绪，FILE_LOADED 时机尚空）。
        EmitLog("info",
                "首帧色彩参数：primaries=" +
                    GetStringProperty("video-params/primaries") +
                    "，gamma=" + GetStringProperty("video-params/gamma") +
                    "，colormatrix=" + GetStringProperty("video-params/colormatrix") +
                    "，colorlevels=" +
                    GetStringProperty("video-params/colorlevels"));
        const std::string dumped = DumpFirstFrameToBmp(
            source, width, height, render_backend_ == RenderBackend::software);
        if (!dumped.empty()) {
          EmitLog("info", "VBOX_DUMP_FRAME：首个非黑帧已转储 " + dumped);
        }
      }
    }
  }
  bool dropped_for_full_pool = false;
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    // 三槽环池：写入「最旧的空闲槽」（空槽优先）。引擎持有的槽绝不触碰，
    // 其余槽随时可写——引擎按 vsync 持帧 1-2 帧不归还也不再丢帧（卡顿修复）。
    int target = -1;
    uint64_t min_seq = UINT64_MAX;
    for (size_t i = 0; i < kFrameSlotCount; ++i) {
      const FrameSlot& s = frame_slots_[i];
      if (s.locked) {
        continue;
      }
      if (s.seq == 0) {
        target = static_cast<int>(i);
        break;
      }
      if (s.seq < min_seq) {
        min_seq = s.seq;
        target = static_cast<int>(i);
      }
    }
    if (target >= 0) {
      FrameSlot& slot = frame_slots_[target];
      slot.buffer.swap(source);
      slot.width = width;
      slot.height = height;
      slot.seq = ++frame_seq_;
    } else if (!logged_frame_drop_) {
      // 3 槽全被引擎持有（异常长持有）：留痕一次后丢弃本帧。
      logged_frame_drop_ = true;
      dropped_for_full_pool = true;
    }
  }
  if (dropped_for_full_pool) {
    EmitLog("warn",
            "帧池 3 槽全部被引擎持有，本帧被丢弃（若持续出现则画面会停滞）");
    return;
  }

  const int64_t texture_id = texture_id_.load();
  if (texture_registrar_ != nullptr && texture_id >= 0) {
    texture_registrar_->MarkTextureFrameAvailable(texture_id);
  }

  if (first_non_black_frame) {
    EmitLog("info",
            "首个非黑帧已渲染上屏（渲染" + std::to_string(width) + "x" +
                std::to_string(height) + "，视频" +
                std::to_string(video_width) + "x" + std::to_string(video_height) +
                "，textureId=" + std::to_string(texture_id) + "，后端=" +
                (render_backend_ == RenderBackend::software ? "software"
                                                            : "opengl") +
                "）");
  }

  // 视频尺寸变更上报（Dart 侧输出面纵横比自适应；去重避免抖动）。
  // 始终按视频原始尺寸上报——按显示尺寸渲染时不能让渲染目标尺寸参与
  // 纵横比计算（纵横比必须由视频本身决定）。
  if (video_width != last_video_width_ || video_height != last_video_height_) {
    last_video_width_ = video_width;
    last_video_height_ = video_height;
    EmitVideoSize(video_width, video_height);
  }
}

// 软件渲染后端逐帧输出：libswscale 把视频帧直接写成 BGRA，无 GPU 依赖。
//
// 参数口径与改造前的 SW 路径一致（`SW_SIZE` / `SW_FORMAT="bgra"` / `SW_STRIDE`
// / `SW_POINTER`）：SW 后端输出本就为顶行在上，无需 `FLIP_Y`（该参数仅 OpenGL
// 路径需要，因为 GL 纹理原点在左下）。
void PlayerPlugin::RenderFrameSoftware(int video_width, int video_height,
                                       int target_width, int target_height) {
  // 按显示尺寸渲染（缩小由 mpv 缩放器完成，见 RenderFrame 注释）；
  // SW 输出顶行在上，无需 FLIP_Y（GL 纹理原点在左下，仅 OpenGL 路径需要）。
  const size_t stride = static_cast<size_t>(target_width) * 4;
  const size_t bytes = stride * static_cast<size_t>(target_height);
  if (sw_frame_width_ != target_width || sw_frame_height_ != target_height ||
      sw_frame_buffer_.size() != bytes) {
    sw_frame_buffer_.assign(bytes, 0);
    sw_frame_width_ = target_width;
    sw_frame_height_ = target_height;
  }
  int size[2] = {target_width, target_height};
  size_t sw_stride = stride;
  const char* format = "bgra";
  void* pointer = sw_frame_buffer_.data();
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_SW_SIZE, size},
      {MPV_RENDER_PARAM_SW_FORMAT, const_cast<char*>(format)},
      {MPV_RENDER_PARAM_SW_STRIDE, &sw_stride},
      {MPV_RENDER_PARAM_SW_POINTER, pointer},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  if (api_.render_context_render(render_ctx_, params) < 0) {
    if (!logged_render_failure_) {
      logged_render_failure_ = true;
      EmitLog("error", "mpv 软件渲染失败（SW），视频帧无法渲染");
    }
    return;
  }
  if (api_.render_context_report_swap != nullptr) {
    api_.render_context_report_swap(render_ctx_);
  }
  PublishFrame(sw_frame_buffer_, target_width, target_height, video_width,
               video_height);
}

void PlayerPlugin::RenderFrame() {
  if (render_ctx_ == nullptr || api_.render_context_render == nullptr) {
    return;
  }
  // 注：此处不再以 video-params/pixelformat 为空作渲染门槛（3.1859 引入的
  // pixelformat 闸门是黑屏回归点之一）。真实视频帧解出前，ResolveVideoSize
  // 会因尺寸未就绪而 return，已足够避免空帧发布；色彩参数改由首帧渲染成功
  // 后统一留痕（见 PublishFrame）。
  int pixel_width = 0;
  int pixel_height = 0;
  if (!ResolveVideoSize(&pixel_width, &pixel_height)) {
    return;
  }
  // 渲染目标 = 引擎显示尺寸（CopyPixelBuffer 回调入参）。Flutter 引擎要求
  // 返回的 buffer 尺寸严格等于其传入的显示尺寸，否则触发 fastfail
  // (0xC0000409，实测 3.1857 闪退根因)。故此处不做「min(视频, 显示)」——
  // 视频无论放大还是缩小，统一渲染到显示尺寸，缩放全部交给 mpv 高质量
  // 缩放器（ewa_lanczossharp + correct-downscaling），渲染目标尺寸恒与引擎
  // 显示尺寸一致，同时规避引擎二次 bilinear 缩放导致的发虚/偏色。
  int target_width = pixel_width;  // 显示尺寸未上报（首帧前）时兜底视频尺寸
  int target_height = pixel_height;
  const int req_width = requested_width_.load(std::memory_order_relaxed);
  const int req_height = requested_height_.load(std::memory_order_relaxed);
  if (req_width >= 64 && req_height >= 64) {
    target_width = req_width;
    target_height = req_height;
  }
  if (render_backend_ == RenderBackend::software) {
    RenderFrameSoftware(pixel_width, pixel_height, target_width, target_height);
    return;
  }
  if (!EnsureFbo(target_width, target_height)) {
    if (!logged_render_failure_) {
      logged_render_failure_ = true;
      EmitLog("error",
              "离屏 FBO 创建失败（" + std::to_string(target_width) + "x" +
                  std::to_string(target_height) +
                  "），视频帧无法上屏；请检查显卡驱动与 OpenGL 版本");
    }
    return;
  }

  // 问题 5：OpenGL 离屏渲染到 FBO（internal_format=0 由 mpv 选择），
  // mpv 在 GPU 上完成完整色彩管线（primaries/gamma/HDR tone-mapping）。
  // mpv 按视频纵横比信箱化适配 FBO，FBO 与视频宽高不一致也不会拉伸。
  mpv_opengl_fbo fbo{};
  fbo.fbo = static_cast<int>(render_fbo_);
  fbo.w = target_width;
  fbo.h = target_height;
  fbo.internal_format = 0;
  int flip_y = 1;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
      {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  if (api_.render_context_render(render_ctx_, params) < 0) {
    if (!logged_render_failure_) {
      logged_render_failure_ = true;
      EmitLog("error", "mpv_render_context_render 失败，视频帧无法渲染");
    }
    return;
  }

  // ADVANCED_CONTROL 契约：每渲染一帧回报一次 swap，维持 mpv 帧节流/播速/timing
  // 正确（缺失会导致卡顿与刷新时机漂移，见 ShutdownMpv 注释与 AGENTS.md）。
  if (api_.render_context_report_swap != nullptr) {
    api_.render_context_report_swap(render_ctx_);
  }

  // 回读同步（云电脑/虚拟显卡花屏修复）：render_context_render 提交的是异步
  // GPU 命令，虚拟显卡 / 软渲染 OpenGL 下 glReadPixels 可能读到尚未完成的帧
  // 缓冲 → 画面撕裂 / 上一帧残留（叠影）/ 颜色错乱。回读前显式 glFinish
  // 强制 GPU 完成渲染，保证取到完整已渲染帧。
  if (gl_.finish != nullptr) {
    gl_.finish();
  }

  // 回读 BGRA 到引擎前缓冲（纹理上屏管线与旧 SW 路径一致，Dart 侧零改动）。
  const size_t row_bytes = static_cast<size_t>(target_width) * 4;
  std::vector<uint8_t> scratch(row_bytes * static_cast<size_t>(target_height));
  gl_.pixel_store_i(kGlPackAlignment, 1);
  gl_.bind_framebuffer(kGlFramebuffer, render_fbo_);
  gl_.read_pixels(0, 0, target_width, target_height, kGlBgra, kGlUnsignedByte,
                  scratch.data());
  gl_.bind_framebuffer(kGlFramebuffer, 0);

  PublishFrame(scratch, target_width, target_height, pixel_width, pixel_height);
}

// 引擎持有缓冲的释放上下文（多槽并发持有 → 每次归还需定位具体槽）。
struct FrameReleaseContext {
  PlayerPlugin* plugin;
  size_t slot_index;
};

const FlutterDesktopPixelBuffer* PlayerPlugin::CopyPixelBuffer(size_t width,
                                                               size_t height) {
  // 引擎回调入参即纹理显示尺寸（物理像素）：记录之，渲染线程下一帧严格
  // 按此尺寸渲染（引擎要求 buffer 尺寸一致，否则 fastfail 0xC0000409）。
  if (width > 0 && height <= static_cast<size_t>(0x7FFFFFFF)) {
    requested_width_.store(static_cast<int>(width), std::memory_order_relaxed);
    requested_height_.store(static_cast<int>(height),
                            std::memory_order_relaxed);
  }
  std::lock_guard<std::mutex> lock(frame_mutex_);
  // 取「最新的空闲槽」（引擎总是希望拿到最新画面）。
  int best = -1;
  for (size_t i = 0; i < kFrameSlotCount; ++i) {
    const FrameSlot& s = frame_slots_[i];
    if (s.locked || s.seq == 0 || s.buffer.empty()) {
      continue;
    }
    if (best < 0 || s.seq > frame_slots_[best].seq) {
      best = static_cast<int>(i);
    }
  }
  if (best < 0) {
    return nullptr;  // 帧池空（首帧前）或全被持有 → 引擎沿用既有纹理
  }
  FrameSlot& slot = frame_slots_[best];
  // 尺寸一致性防御：Flutter 引擎要求返回 buffer 尺寸 == 其传入的显示尺寸，
  // 否则触发 fastfail（0xC0000409）。resize / 首帧瞬态下渲染线程可能尚未
  // 按新显示尺寸出帧，此时返回 nullptr 让引擎沿用上一帧，杜绝尺寸不一致。
  if (static_cast<size_t>(slot.width) != width ||
      static_cast<size_t>(slot.height) != height) {
    return nullptr;
  }
  pixel_buffer_.buffer = slot.buffer.data();
  pixel_buffer_.width = static_cast<size_t>(slot.width);
  pixel_buffer_.height = static_cast<size_t>(slot.height);
  pixel_buffer_.release_callback = &PlayerPlugin::OnPixelBufferReleased;
  pixel_buffer_.release_context = new FrameReleaseContext{
      this, static_cast<size_t>(best)};
  slot.locked = true;
  return &pixel_buffer_;
}

void PlayerPlugin::OnPixelBufferReleased(void* release_context) {
  auto* ctx = static_cast<FrameReleaseContext*>(release_context);
  if (ctx == nullptr) {
    return;
  }
  PlayerPlugin* self = ctx->plugin;
  const size_t index = ctx->slot_index;
  delete ctx;
  {
    std::lock_guard<std::mutex> lock(self->frame_mutex_);
    if (index < PlayerPlugin::kFrameSlotCount) {
      FrameSlot& slot = self->frame_slots_[index];
      slot.locked = false;
      // 复位代际与尺寸（防旧帧被新会话误取）；buffer 内存保留不 clear——
      // 此刻刚解除锁定，若在此 clear 而渲染线程随即 swap 该槽，存在 vector
      // 内部状态竞争（同 ShutdownMpv 的 0xC0000409 根因）。内存将在该槽被
      // PublishFrame 重新装入新帧时自然回收。
      slot.seq = 0;
      slot.width = 0;
      slot.height = 0;
    }
  }
  // 唤醒 ShutdownMpv 中等待缓冲归还的线程（有界等待，见 ShutdownMpv）。
  self->frame_cv_.notify_all();
}

void PlayerPlugin::RunEventLoop() {
  while (running_.load()) {
    // 短超时轮询：支持 running_ 标志及时退出。
    mpv_event* event = api_.wait_event(mpv_, 0.1);
    if (event == nullptr) {
      continue;
    }
    if (event->event_id == MPV_EVENT_SHUTDOWN) {
      break;
    }
    HandleMpvEvent(event);
  }
}

void PlayerPlugin::HandleMpvEvent(const mpv_event* event) {
  switch (event->event_id) {
    case MPV_EVENT_START_FILE:
      EmitState("opening");
      break;
    case MPV_EVENT_FILE_LOADED: {
      // 文件加载完成：是否起播取决于 pause 属性。
      int paused = 0;
      const bool has_pause = GetFlagProperty("pause", &paused);
      EmitState(has_pause && paused ? "paused" : "playing");
      // 记录媒体信息，便于判断「有声音无画面」是否因缺视频轨 / 解码失败。
      double duration = -1.0;
      GetDoubleProperty("duration", &duration);
      int64_t width = 0;
      int64_t height = 0;
      const bool has_video = GetInt64Property("width", &width) && width > 0 &&
                             GetInt64Property("height", &height) && height > 0;
      const std::string video = has_video
                                    ? std::to_string(width) + "x" + std::to_string(height)
                                    : "无（纯音频）";
      EmitLog("info", "文件已加载：时长=" +
                          (duration > 0
                               ? std::to_string(static_cast<int64_t>(duration)) + "秒"
                               : std::string("未知")) +
                          "，视频轨尺寸=" + video);
      // 色彩参数留痕（画质/偏色排查）：pixelformat/primaries/gamma 一眼定位
      // HDR（bt.2020+pq/hlg）与 601/709 疑问；hwdec-current 供解码路径比对。
      if (has_video) {
        const std::string pixfmt = GetStringProperty("video-params/pixelformat");
        const std::string primaries =
            GetStringProperty("video-params/primaries");
        const std::string gamma = GetStringProperty("video-params/gamma");
        const std::string hwdec = GetStringProperty("hwdec-current");
        EmitLog("info",
                "视频色彩参数：pixfmt=" + pixfmt + "，primaries=" + primaries +
                    "，gamma=" + gamma + "，hwdec=" +
                    (hwdec.empty() ? std::string("no") : hwdec));
      }
      EmitProgress();
      break;
    }
    case MPV_EVENT_PLAYBACK_RESTART: {
      int paused = 0;
      const bool has_pause = GetFlagProperty("pause", &paused);
      EmitState(has_pause && paused ? "paused" : "playing");
      break;
    }
    case MPV_EVENT_END_FILE: {
      const auto* end_file =
          static_cast<const mpv_event_end_file*>(event->data);
      if (end_file != nullptr &&
          end_file->reason == MPV_END_FILE_REASON_ERROR) {
        const char* detail = api_.error_string(end_file->error);
        const std::string message = detail != nullptr ? detail : "播放失败";
        EmitLog("error", "播放中断：" + message);
        EmitError(message, true);
        EmitState("error");
      } else if (end_file != nullptr &&
                 end_file->reason == MPV_END_FILE_REASON_EOF) {
        EmitLog("info", "播放到文件末尾");
        EmitState("ended");
      }
      break;
    }
    case MPV_EVENT_PROPERTY_CHANGE: {
      const auto* prop = static_cast<const mpv_event_property*>(event->data);
      if (prop == nullptr) {
        break;
      }
      const std::string name = prop->name != nullptr ? prop->name : "";
      if (name == "time-pos" || name == "duration") {
        EmitProgress();
      } else if (name == "pause") {
        int paused = 0;
        if (prop->format == MPV_FORMAT_FLAG && prop->data != nullptr) {
          paused = *static_cast<const int*>(prop->data);
        }
        EmitState(paused ? "paused" : "playing");
      } else if (name == "paused-for-cache") {
        int caching = 0;
        if (prop->format == MPV_FORMAT_FLAG && prop->data != nullptr) {
          caching = *static_cast<const int*>(prop->data);
        }
        if (caching) {
          EmitState("buffering");
        } else {
          int paused = 0;
          const bool has_pause = GetFlagProperty("pause", &paused);
          EmitState(has_pause && paused ? "paused" : "playing");
        }
      }
      break;
    }
    case MPV_EVENT_LOG_MESSAGE: {
      // mpv 内部日志（对齐 iOS 详细度）：前缀 + 文本上抛 Dart AppLog。
      const auto* log = static_cast<const mpv_event_log_message*>(event->data);
      if (log == nullptr || log->text == nullptr) {
        break;
      }
      std::string level = log->level != nullptr ? log->level : "info";
      std::string mapped = "debug";
      if (level == "fatal" || level == "error") {
        mapped = "error";
      } else if (level == "warn") {
        mapped = "warn";
      } else if (level == "info") {
        mapped = "info";
      }
      std::string text = log->text;
      while (!text.empty() &&
             (text.back() == '\n' || text.back() == '\r')) {
        text.pop_back();
      }
      const std::string prefix = log->prefix != nullptr ? log->prefix : "mpv";
      EmitLog(mapped, "[mpv/" + prefix + "] " + text);
      break;
    }
    default:
      // MPV_EVENT_NONE / QUEUE_OVERFLOW 等：控制面忽略。
      break;
  }
}

// ─────────────── 事件面 ───────────────

void PlayerPlugin::EmitState(const std::string& value) {
  state_ = value;
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink =
      SinkSnapshot();
  if (sink == nullptr) {
    return;
  }
  sink->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue(std::string("type")),
       flutter::EncodableValue(std::string("state"))},
      {flutter::EncodableValue(std::string("value")),
       flutter::EncodableValue(value)},
  }));
}

void PlayerPlugin::EmitProgress() {
  if (mpv_ == nullptr) {
    return;
  }
  double position_seconds = -1.0;
  double duration_seconds = -1.0;
  double buffered_seconds = -1.0;
  GetDoubleProperty("time-pos", &position_seconds);
  GetDoubleProperty("duration", &duration_seconds);
  GetDoubleProperty("demuxer-cache-time", &buffered_seconds);

  const bool is_live = duration_seconds < 0.0;
  const int64_t position_ms =
      position_seconds < 0.0 ? 0 : static_cast<int64_t>(position_seconds * 1000.0);
  const int64_t duration_ms =
      is_live ? 0 : static_cast<int64_t>(duration_seconds * 1000.0);
  const int64_t buffered_ms =
      buffered_seconds < 0.0 ? 0 : static_cast<int64_t>(buffered_seconds * 1000.0);

  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink =
      SinkSnapshot();
  if (sink == nullptr) {
    return;
  }
  sink->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue(std::string("type")),
       flutter::EncodableValue(std::string("progress"))},
      {flutter::EncodableValue(std::string("positionMs")),
       flutter::EncodableValue(position_ms)},
      {flutter::EncodableValue(std::string("durationMs")),
       flutter::EncodableValue(duration_ms)},
      {flutter::EncodableValue(std::string("bufferedMs")),
       flutter::EncodableValue(buffered_ms)},
      {flutter::EncodableValue(std::string("isLive")),
       flutter::EncodableValue(is_live)},
  }));
}

void PlayerPlugin::EmitVideoSize(int width, int height) {
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink =
      SinkSnapshot();
  if (sink == nullptr) {
    return;
  }
  sink->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue(std::string("type")),
       flutter::EncodableValue(std::string("videoSize"))},
      {flutter::EncodableValue(std::string("width")),
       flutter::EncodableValue(width)},
      {flutter::EncodableValue(std::string("height")),
       flutter::EncodableValue(height)},
  }));
}

void PlayerPlugin::EmitError(const std::string& message, bool fatal) {
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink =
      SinkSnapshot();
  if (sink == nullptr) {
    return;
  }
  sink->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue(std::string("type")),
       flutter::EncodableValue(std::string("error"))},
      {flutter::EncodableValue(std::string("message")),
       flutter::EncodableValue(message)},
      {flutter::EncodableValue(std::string("fatal")),
       flutter::EncodableValue(fatal)},
  }));
}

void PlayerPlugin::EmitTextureReady(int64_t texture_id) {
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink =
      SinkSnapshot();
  if (sink == nullptr) {
    return;
  }
  sink->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue(std::string("type")),
       flutter::EncodableValue(std::string("textureReady"))},
      {flutter::EncodableValue(std::string("textureId")),
       flutter::EncodableValue(texture_id)},
  }));
}

bool PlayerPlugin::GetDoubleProperty(const char* name, double* out) {
  if (mpv_ == nullptr) {
    return false;
  }
  double value = -1.0;
  const int rc = api_.get_property(mpv_, name, MPV_FORMAT_DOUBLE, &value);
  if (rc < 0) {
    return false;
  }
  *out = value;
  return true;
}

bool PlayerPlugin::GetFlagProperty(const char* name, int* out) {
  if (mpv_ == nullptr) {
    return false;
  }
  int value = 0;
  const int rc = api_.get_property(mpv_, name, MPV_FORMAT_FLAG, &value);
  if (rc < 0) {
    return false;
  }
  *out = value;
  return true;
}

bool PlayerPlugin::GetInt64Property(const char* name, int64_t* out) {
  if (mpv_ == nullptr) {
    return false;
  }
  int64_t value = 0;
  const int rc = api_.get_property(mpv_, name, MPV_FORMAT_INT64, &value);
  if (rc < 0) {
    return false;
  }
  *out = value;
  return true;
}

std::string PlayerPlugin::GetStringProperty(const char* name) {
  if (mpv_ == nullptr) {
    return std::string();
  }
  // MPV_FORMAT_STRING：mpv 分配字符串，调用方经 mpv_free 释放。
  char* value = nullptr;
  if (api_.get_property(mpv_, name, MPV_FORMAT_STRING, &value) < 0 ||
      value == nullptr) {
    return std::string();
  }
  std::string result = value;
  if (api_.free != nullptr) {
    api_.free(value);
  }
  return result;
}

}  // namespace vbox
