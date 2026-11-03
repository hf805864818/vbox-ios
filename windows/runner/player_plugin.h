//
//  player_plugin.h
//  Runner
//
//  批次 C · C-11：Windows 播放器插件（libmpv 主后端）。
//  Wave A · R-渲1：补视频纹理输出面（mpv_render_context SW + Flutter TextureRegistrar）。
//
//  与 macOS `PlayerPlugin.swift` / Android `PlayerPlugin.kt` 共用同一 wire 协议
//  （Dart `ChannelPlayer._onEvent` 解析面）：
//    · MethodChannel `com.vbox.player/player`：open / play / pause / seekTo /
//      setVolume / setSpeed / dispose
//    · EventChannel `com.vbox.player/player/events`：state / progress / videoSize / error
//
//  后端口径（D6）：Windows/macOS 主后端 libmpv。libmpv 运行时（mpv-2.dll）按
//  D28 分发决策随安装包同目录分发（不入 git，由 scripts/bundle-libmpv-windows.ps1
//  从 GitHub Release 资产拉取并改名 mpv-2.dll 拷入 runner 目录），插件运行期
//  LoadLibraryW + GetProcAddress 动态解析，构建期不依赖第三方导入库。
//
//  渲染口径（R-渲1 · 问题 5）：`vo=libmpv`（render API 前置）+ `gpu-api=opengl`
//  + `mpv_render_context`（OpenGL/GPU 后端，`MPV_RENDER_API_TYPE_OPENGL`）：mpv
//  在 GPU 上跑完整色彩管线（primaries/gamma/HDR tone-mapping，对齐 iOS）渲染到
//  离屏 FBO，再 `glReadPixels` 回读 BGRA，经 Flutter `TextureRegistrar`
//  （[PixelBufferTexture]）上屏；`open` 返回 `textureId` 交 Dart `Texture(textureId:)`
//  承载。视频尺寸经 `videoSize` 事件上报，Dart 侧按纵横比自适应（对齐 iOS
//  `videoGravity = .resizeAspect`）。
//
//  事件面实现：专属事件线程轮询 mpv_wait_event，事件经 EventSink 上抛；
//  进度与状态由 mpv_observe_property 属性变更驱动（对齐契约 §2.5 能力矩阵）。

#ifndef RUNNER_PLAYER_PLUGIN_H_
#define RUNNER_PLAYER_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <windows.h>

#include "libmpv/client.h"

namespace vbox {

// ─────────────── libmpv render API（OpenGL/GPU 后端）───────────────
//
// `libmpv/render.h` 未随仓库分发（仅 client.h），此处按 mpv ABI 手动声明本插件
// 用到的渲染子集；枚举值与 mpv 官方 render.h 一一对应（0~20），不得改动顺序。
struct mpv_render_context;
typedef void (*mpv_render_update_fn)(void* callback_ctx);
typedef uint64_t mpv_render_update_flag;

enum mpv_render_param_type {
  MPV_RENDER_PARAM_INVALID = 0,
  MPV_RENDER_PARAM_API_TYPE = 1,
  MPV_RENDER_PARAM_OPENGL_INIT_PARAMS = 2,
  MPV_RENDER_PARAM_OPENGL_FBO = 3,
  MPV_RENDER_PARAM_FLIP_Y = 4,
  MPV_RENDER_PARAM_DEPTH = 5,
  MPV_RENDER_PARAM_ICC_PROFILE = 6,
  MPV_RENDER_PARAM_AMBIENT_LIGHT = 7,
  MPV_RENDER_PARAM_X11_DISPLAY = 8,
  MPV_RENDER_PARAM_WL_DISPLAY = 9,
  MPV_RENDER_PARAM_ADVANCED_CONTROL = 10,
  MPV_RENDER_PARAM_NEXT_FRAME_INFO = 11,
  MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME = 12,
  MPV_RENDER_PARAM_SKIP_RENDERING = 13,
  MPV_RENDER_PARAM_DRM_DISPLAY = 14,
  MPV_RENDER_PARAM_DRM_DRAW_SURFACE_SIZE = 15,
  MPV_RENDER_PARAM_DRM_DISPLAY_V2 = 16,
  MPV_RENDER_PARAM_SW_SIZE = 17,
  MPV_RENDER_PARAM_SW_FORMAT = 18,
  MPV_RENDER_PARAM_SW_STRIDE = 19,
  MPV_RENDER_PARAM_SW_POINTER = 20,
};

struct mpv_render_param {
  enum mpv_render_param_type type;
  void* data;
};

// `mpv_opengl_init_params`（render.h）：OpenGL render context 初始化参数。
// `get_proc_address` 供 mpv 解析 GL 入口（Windows 下用 wglGetProcAddress 包装）。
struct mpv_opengl_init_params {
  void* (*get_proc_address)(void* ctx, const char* name);
  void* get_proc_address_ctx;
};

// `mpv_opengl_fbo`（render.h）：OpenGL 离屏渲染目标。
struct mpv_opengl_fbo {
  int fbo;
  int w;
  int h;
  int internal_format;
};

// 渲染 api type 字符串（MPV_RENDER_API_TYPE_OPENGL）。问题 5：桌面改走 GPU
// render context，让 mpv 在 GPU 上跑完整色彩管线（primaries/gamma/HDR
// tone-mapping），对齐 iOS 的 GPU 渲染路径，消除 SW 软渲染的泛黄偏色。
constexpr const char* kRenderApiGl = "opengl";
// 渲染 api type 字符串（MPV_RENDER_API_TYPE_SW）。问题 2 兜底：OpenGL 离屏
// 渲染不可用（无显卡驱动 / 远程桌面会话 / 仅 OpenGL 1.1）时退到 libswscale
// 软渲染，保证仍有画面而不是只剩音频。色彩表现不如 GPU 路径（无色彩管理）。
constexpr const char* kRenderApiSw = "sw";
// mpv_render_context_update 返回标志：有新帧可渲染。
constexpr mpv_render_update_flag kRenderUpdateFrame = 1;

// 实际生效的视频输出后端（render context 建成后确定，渲染线程内读写）。
enum class RenderBackend {
  none,      // 未建（或已释放）
  opengl,    // GPU 离屏 FBO + glReadPixels
  software,  // libswscale 软渲染直出 BGRA
};

// ─────────────── OpenGL / WGL 运行期符号（R-渲1 · GPU）───────────────
//
// 不引入 GL/gl.h：手动声明本插件用到的 GL 子集，运行期经 wglGetProcAddress
// （扩展入口）或 GetProcAddress(opengl32.dll)（GL 1.1 入口）解析。
using GlEnum = unsigned int;
using GlUint = unsigned int;
using GlInt = int;
using GlSizei = int;

struct GlApi {
  void (*gen_textures)(GlSizei, GlUint*) = nullptr;
  void (*delete_textures)(GlSizei, const GlUint*) = nullptr;
  void (*bind_texture)(GlEnum, GlUint) = nullptr;
  void (*tex_image_2d)(GlEnum, GlInt, GlInt, GlSizei, GlSizei, GlInt, GlEnum,
                       GlEnum, const void*) = nullptr;
  void (*tex_parameter_i)(GlEnum, GlEnum, GlInt) = nullptr;
  void (*pixel_store_i)(GlEnum, GlInt) = nullptr;
  void (*gen_framebuffers)(GlSizei, GlUint*) = nullptr;
  void (*delete_framebuffers)(GlSizei, const GlUint*) = nullptr;
  void (*bind_framebuffer)(GlEnum, GlUint) = nullptr;
  void (*framebuffer_texture_2d)(GlEnum, GlEnum, GlEnum, GlUint, GlInt) =
      nullptr;
  GlEnum (*check_framebuffer_status)(GlEnum) = nullptr;
  void (*viewport)(GlInt, GlInt, GlSizei, GlSizei) = nullptr;
  void (*read_pixels)(GlInt, GlInt, GlSizei, GlSizei, GlEnum, GlEnum,
                      void*) = nullptr;
  // glFinish：回读前强制 GPU 完成渲染，避免虚拟显卡/软渲染 OpenGL 下
  // glReadPixels 读到未完成帧缓冲导致的花屏/叠影（GL 1.1 导出，恒存在）。
  void (*finish)(void) = nullptr;
};

// WGL 入口（opengl32.dll；渲染线程内 wglMakeCurrent 绑定，线程亲和）。
struct WglApi {
  HGLRC (*create_context)(HDC) = nullptr;
  BOOL (*make_current)(HDC, HGLRC) = nullptr;
  BOOL (*delete_context)(HGLRC) = nullptr;
  void* (*get_proc_address)(const char*) = nullptr;
};

// libmpv C API 函数指针表（mpv-2.dll 运行期动态解析）。
// 仅收录本插件用到的符号；签名与 libmpv/client.h / render.h 一一对应。
struct MpvApi {
  // 加载状态（首次 open 前尝试 LoadLibraryW）。
  bool loaded = false;

  // 最近一次 Load 失败原因（GetLastError 分类，供 open 报错给 Dart）。
  std::string load_error;

  // 句柄与生命周期。
  mpv_handle* (*create)(void) = nullptr;
  int (*initialize)(mpv_handle* ctx) = nullptr;
  void (*terminate_destroy)(mpv_handle* ctx) = nullptr;

  // 命令与选项。
  int (*command)(mpv_handle* ctx, const char** args) = nullptr;
  int (*set_option_string)(mpv_handle* ctx, const char* name,
                           const char* data) = nullptr;

  // 属性读写。
  int (*set_property)(mpv_handle* ctx, const char* name, mpv_format format,
                      void* data) = nullptr;
  int (*get_property)(mpv_handle* ctx, const char* name, mpv_format format,
                      void* data) = nullptr;

  // 事件面。
  int (*observe_property)(mpv_handle* ctx, uint64_t reply_userdata,
                          const char* name, mpv_format format) = nullptr;
  int (*unobserve_property)(mpv_handle* ctx,
                            uint64_t registered_reply_userdata) = nullptr;
  mpv_event* (*wait_event)(mpv_handle* ctx, double timeout) = nullptr;

  // 工具。
  const char* (*error_string)(int error) = nullptr;
  void (*free)(void* data) = nullptr;

  // 日志面（可选：旧 dll 缺失时保持 nullptr，仅少了 mpv 内部日志上抛）。
  int (*request_log_messages)(mpv_handle* ctx, const char* min_level) = nullptr;

  // ── render API（R-渲1；可选：旧 dll 缺失时为 nullptr → 无纹理输出）──
  int (*render_context_create)(mpv_render_context** res, mpv_handle* ctx,
                               mpv_render_param* params) = nullptr;
  int (*render_context_render)(mpv_render_context* ctx,
                               mpv_render_param* params) = nullptr;
  void (*render_context_set_update_callback)(mpv_render_context* ctx,
                                             mpv_render_update_fn callback,
                                             void* callback_ctx) = nullptr;
  mpv_render_update_flag (*render_context_update)(mpv_render_context* ctx) =
      nullptr;
  void (*render_context_free)(mpv_render_context* ctx) = nullptr;
  // 帧已呈现回报（R-渲1）：ADVANCED_CONTROL 契约要求每渲染一帧调用一次，
  // 否则 mpv 的帧节流/播速/timing 会漂移，见 AGENTS.md「已知待决问题」。
  void (*render_context_report_swap)(mpv_render_context* ctx) = nullptr;

  // 加载 mpv-2.dll 并解析全部符号；失败时 loaded=false。
  bool Load();
};

// 百度 bdstoken 原生 WebView2 桥（完整定义见 baidu_token_bridge.h）。
class BaiduTokenBridge;

// Windows 播放器插件（libmpv + 视频纹理输出面，见文件头注释）。
class PlayerPlugin : public flutter::Plugin {
 public:
  // 手动注册入口（flutter_window.cpp OnCreate 调用，对齐 macOS
  // MainFlutterWindow 的 PlayerPlugin.register 模式）。
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit PlayerPlugin(flutter::PluginRegistrarWindows* registrar);
  virtual ~PlayerPlugin();

  PlayerPlugin(const PlayerPlugin&) = delete;
  PlayerPlugin& operator=(const PlayerPlugin&) = delete;

  // MethodChannel 分派入口（flutter::Plugin 无 HandleMethodCall 虚函数，
  // 由构造期 SetMethodCallHandler lambda 回调）。
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 云侧桥通道分派（`com.vbox.player/cloud_bridge`：原生 WebView2 取
  // bdstoken，见 baidu_token_bridge.h）。
  void HandleCloudMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // ── 供 StreamHandler 调用的 sink 生命周期（事件线程安全） ──
  void SetSink(
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);
  void ClearSink();

 private:
  // 事件流处理器（onListen/onCancel 挂接 sink）。
  class StreamHandler
      : public flutter::StreamHandler<flutter::EncodableValue> {
   public:
    explicit StreamHandler(PlayerPlugin* plugin) : plugin_(plugin) {}

    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
    OnListenInternal(const flutter::EncodableValue* arguments,
                     std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                         events) override;

    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
    OnCancelInternal(const flutter::EncodableValue* arguments) override;

   private:
    PlayerPlugin* plugin_;
  };

  // ── 通道 ──
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      cloud_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<StreamHandler> stream_handler_;
  std::mutex sink_mutex_;
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;

  // ── 百度 bdstoken 原生 WebView2 桥（cloud_bridge 后端，
  //    完整类型见 baidu_token_bridge.h）──
  std::unique_ptr<BaiduTokenBridge> baidu_bridge_;

  // ── Flutter 纹理输出面（R-渲1）──
  flutter::TextureRegistrar* texture_registrar_ = nullptr;
  std::unique_ptr<flutter::TextureVariant> texture_;
  // 纹理句柄由渲染线程注册、平台线程读取/注销，跨线程 → 必须原子。
  std::atomic<int64_t> texture_id_{-1};
  FlutterDesktopPixelBuffer pixel_buffer_{};
  std::mutex frame_mutex_;
  // 引擎释放帧缓冲（OnPixelBufferReleased）时的通知：ShutdownMpv 借此有界等待
  // 引擎归还缓冲，避免帧缓冲被提前释放而引擎光栅线程仍在采样（0xC0000409）。
  std::condition_variable frame_cv_;
  // ── 三缓冲帧池（3.1858 卡顿修复）──
  // 旧单缓冲 + frame_locked_ 的架构：引擎持帧未归还期间渲染线程只能丢帧，
  // 引擎按 vsync 采样（60Hz）与 mpv 出帧（视频帧率）节奏不齐时高概率撞锁
  // → 周期性丢帧 = 「一卡一卡」。改为 3 槽环池：渲染线程写入最旧的空闲槽，
  // 引擎取最新的空闲槽，读写永不互斥；3 槽同时覆盖「引擎迟归还 1-2 帧」的
  // 常态抖动，仅全部被锁时才丢帧（理论上不再出现）。
  struct FrameSlot {
    std::vector<uint8_t> buffer;  // BGRA8888
    int width = 0;
    int height = 0;
    bool locked = false;  // 引擎持有中（CopyPixelBuffer 后至 release 间）
    uint64_t seq = 0;     // 发布序号（0 = 空槽），引擎取最大者
  };
  static constexpr size_t kFrameSlotCount = 3;
  FrameSlot frame_slots_[kFrameSlotCount];
  uint64_t frame_seq_ = 0;
  // 引擎光栅线程经 CopyPixelBuffer 回报的显示尺寸（物理像素）。渲染目标
  // 恒等于该尺寸（引擎要求 buffer 尺寸严格一致，否则 fastfail），缩放全部
  // 由 mpv 高质量缩放器完成。光栅线程写、渲染线程读，原子访问。
  std::atomic<int> requested_width_{0};
  std::atomic<int> requested_height_{0};
  int last_video_width_ = 0;   // 上次上报的视频尺寸（去重）
  int last_video_height_ = 0;

  // ── libmpv ──
  MpvApi api_;
  mpv_handle* mpv_ = nullptr;
  mpv_render_context* render_ctx_ = nullptr;
  std::unique_ptr<std::thread> event_thread_;
  std::atomic<bool> running_{false};
  std::unique_ptr<std::thread> render_thread_;
  std::atomic<bool> render_running_{false};
  std::atomic<bool> render_requested_{false};
  std::mutex render_mutex_;
  std::condition_variable render_cv_;

  // ── OpenGL / WGL 渲染上下文（R-渲1 · GPU；渲染线程亲和）──
  GlApi gl_;
  WglApi wgl_;
  HMODULE opengl32_ = nullptr;   // opengl32.dll（GL 1.1 入口 + WGL）
  HWND render_hwnd_ = nullptr;   // 隐藏窗口（仅承载 WGL 上下文）
  HDC render_hdc_ = nullptr;
  HGLRC render_glrc_ = nullptr;
  GlUint render_fbo_ = 0;        // 离屏 FBO（mpv 渲染目标）
  GlUint render_tex_ = 0;        // FBO 颜色纹理
  int fbo_width_ = 0;
  int fbo_height_ = 0;
  // 当前生效的视频输出后端（OpenGL 失败后由 RunRenderLoop 退到 software）。
  RenderBackend render_backend_ = RenderBackend::none;
  // 预检结论：软渲染 OpenGL / 远程桌面会话 → 跳过 OpenGL 离屏路径，直接走 SW。
  // 平台线程（ProbeGlCapability）写入，渲染线程（RunRenderLoop）读取，
  // 仅在 Open 流程串行使用，无并发风险。
  bool prefer_software_render_ = false;
  // 软渲染输出缓冲（BGRA8888；尺寸随视频变化重建，仅 software 后端使用）。
  std::vector<uint8_t> sw_frame_buffer_;
  int sw_frame_width_ = 0;
  int sw_frame_height_ = 0;
  // 日志去重：首帧渲染成功 / 首次渲染失败 / 首次持续丢帧只上报一次，避免刷屏。
  bool logged_first_frame_ = false;
  bool logged_render_failure_ = false;
  bool logged_frame_drop_ = false;
  // 已发布帧计数（前 N 帧逐帧像素统计用，诊断「持续黑屏 vs 首帧假黑」）。
  int frame_publish_count_ = 0;

  // ── 状态 ──
  std::string state_ = "idle";

  // ── 方法面 ──
  void Open(const flutter::EncodableValue* args,
            std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                result);
  void Play(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                result);
  void Pause(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result);
  void SeekTo(const flutter::EncodableValue* args,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                  result);
  void SetVolume(
      const flutter::EncodableValue* args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SetSpeed(const flutter::EncodableValue* args,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                    result);
  void Dispose(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result);

  // ── libmpv 内部 ──
  bool InitializeMpv(bool auto_play);
  void ShutdownMpv();
  void RunEventLoop();
  void HandleMpvEvent(const mpv_event* event);

  // ── 渲染输出面内部（R-渲1 · GPU/OpenGL）──
  static void OnRenderUpdate(void* callback_ctx);
  static void OnPixelBufferReleased(void* release_context);
  bool SetupRenderContext();
  void RunRenderLoop();
  void RenderFrame();
  // 取视频目标尺寸（coded 优先，回退 display；未解出视频轨时返回 false）。
  bool ResolveVideoSize(int* width, int* height);
  // 把一帧 BGRA 交给 Flutter 纹理上屏（两个后端共用：丢帧判定 / 尺寸上报 / 日志）。
  // [width/height] 为本帧缓冲（渲染目标）尺寸；[video_width/video_height] 为
  // 视频原始尺寸（纵横比上报用，与渲染目标解耦——按显示尺寸渲染时二者不同）。
  void PublishFrame(std::vector<uint8_t>& source, int width, int height,
                    int video_width, int video_height);
  // 软件渲染后端：以 "sw" API 建 render context（无需 GL 上下文）。
  bool CreateSwRenderContext();
  // 软件渲染后端逐帧输出（BGRA 直出到 [sw_frame_buffer_]）。
  // 视频尺寸与渲染目标尺寸解耦（按显示尺寸渲染时二者不同，见 RenderFrame）。
  void RenderFrameSoftware(int video_width, int video_height, int target_width,
                           int target_height);
  // 平台无关 GL 能力预检：建临时 WGL 上下文，检查 OpenGL 版本与 FBO 入口，
  // 并识别软渲染 OpenGL / 远程桌面会话（云电脑/虚拟显卡 glReadPixels 回读会
  // 花屏/叠影）。识别到时经 [out_prefer_software] 回传 true，由调用方决定直接
  // 走 libswscale 软渲染。结论同时用于日志提示，不作为 `vo` 的闸门。
  static bool ProbeGlCapability(std::string* detail,
                                bool* out_prefer_software = nullptr);
  // 播放日志上报（经事件通道交 Dart `AppLog`，对齐 iOS 排查详细度）。
  void EmitLog(const std::string& level, const std::string& message);
  // 渲染线程内建/销毁 WGL 上下文 + mpv render_context（WGL 线程亲和）。
  bool CreateGlRenderContext();
  void DestroyGlRenderContext();
  // 渲染线程内解析 opengl32 GL 入口（GL 1.1 + FBO 扩展）。
  bool LoadGlSymbols();
  // 渲染线程内按视频尺寸（懒）建离屏 FBO + 颜色纹理。
  bool EnsureFbo(int width, int height);
  const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t width, size_t height);
  void RegisterTexture();
  void UnregisterTexture();

  // ── 事件面 ──
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> SinkSnapshot();
  void EmitState(const std::string& value);
  void EmitProgress();
  void EmitVideoSize(int width, int height);
  void EmitError(const std::string& message, bool fatal);
  // 纹理注册完成后回传句柄（渲染线程注册 → 平台线程 Open 已提前返回的场景）。
  void EmitTextureReady(int64_t texture_id);

  // 读属性辅助（返回值 <0 表示不可用）。
  bool GetDoubleProperty(const char* name, double* out);
  bool GetFlagProperty(const char* name, int* out);
  bool GetInt64Property(const char* name, int64_t* out);
  // 读字符串属性（如 video-params/pixelformat）；失败返回空串。
  std::string GetStringProperty(const char* name);
};

}  // namespace vbox

#endif  // RUNNER_PLAYER_PLUGIN_H_