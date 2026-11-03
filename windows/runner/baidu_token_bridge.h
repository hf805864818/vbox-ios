//  baidu_token_bridge.h
//  Runner
//
//  百度 bdstoken 原生 WebView2 桥（Windows 专属）。
//
//  背景：普通百度网盘播放链需要用户态 bdstoken，Dart HttpClient 的 TLS/请求
//  指纹被百度风控（gettemplatevariable errno=-6）。iOS 端经 WKWebView（系统
//  网络栈）天然可信；Windows 端 Flutter 插件 WebView 曾先后引入闪退（无头
//  模式）与白屏（根 Overlay 宿主），均已下线。本桥在 runner 原生层直接承载
//  WebView2：屏幕外（虚拟屏之外）但 IsVisible=TRUE 的 owned 弹出窗口 +
//  持久化 Jar + disk/main 页面上下文内 fetch gettemplatevariable——与登录
//  网关同源的浏览器信任路径，不经 Flutter 插件 WebView，结构上不会复现
//  白屏/闪退。
//
//  ⚠ 窗口可见性（3.1854 取号超时根因 + 3.1856 修正）：绝不能用
//  put_IsVisible(FALSE) 或不 ShowWindow 的隐藏窗口导航——WebView2 对不可见
//  Widget 会挂起渲染/推迟 load 完成，NavigationCompleted 迟迟不触发，任何
//  机器（含家宽）都会 25s 看门狗超时。3.1854 曾停靠「虚拟屏右下角之外」，
//  但 Chromium 的 NativeWindowOcclusionTracker 会把完全不在任何显示器区域
//  内的窗口判定为 hidden/occluded → 3.1855 云电脑实测仍超时。3.1856 起
//  对齐 iOS BaiduWebViewBridge（「1x1 WKWebView addSubview 到可见 key
//  window」）：宿主窗口 = 主窗口客户区右下角内侧 2x2 的 owned 弹窗
//  （WS_EX_TRANSPARENT 鼠标穿透 + WS_EX_NOACTIVATE + TOOLWINDOW，用户无感），
//  几何上在屏幕内且位于 owner 之上 → occlusion 判定可见，导航正常完成。
//
//  Dart 侧：lib/platform/webview/baidu_native_token_bridge.dart
//  通道：MethodChannel `com.vbox.player/cloud_bridge` · getBdstoken
//
//  线程模型：全部工作在平台线程（方法调用线程，STA + 消息泵）；WebView2
//  异步完成回调也投递回该线程，无需跨线程同步。
//  生命周期：Controller 常驻复用（首次调用创建，进程退出随插件析构关闭）；
//  取号成功后走快速路径（免导航直接页面 fetch），errno!=0 时种 Cookie 重导航一次。

#ifndef RUNNER_BAIDU_TOKEN_BRIDGE_H_
#define RUNNER_BAIDU_TOKEN_BRIDGE_H_

#include <functional>
#include <string>
#include <vector>

#include <windows.h>

#include <wrl/client.h>

#include <flutter/encodable_value.h>

#include "webview2/include/WebView2.h"

namespace vbox {

class BaiduTokenBridge {
 public:
  /// 结果回调（平台线程调用一次）：EncodableMap
  /// {errno:int, bdstoken:string, cookie:string, message:string}。
  using Reply = std::function<void(const flutter::EncodableValue&)>;

  /// 原生日志回调（PlayerPlugin 接到 `player/events` 事件通道的 log 事件）。
  /// level ∈ {"debug","info","warn","error"}；message 为无时间戳纯文本。
  /// 取号链路每个阶段（固定版加载 / COM / 环境 / 控制器 / 导航 / 脚本）均
  /// 经此回调上抛 Dart AppLog，满足「有错误就打印错误日志」的排查诉求。
  using LogCallback =
      std::function<void(const std::string& level, const std::string& message)>;

  explicit BaiduTokenBridge(HWND parent_window);
  ~BaiduTokenBridge();

  BaiduTokenBridge(const BaiduTokenBridge&) = delete;
  BaiduTokenBridge& operator=(const BaiduTokenBridge&) = delete;

  /// 挂接日志回调（幂等；未挂接时 EmitLog 静默丢弃）。
  void SetLogCallback(LogCallback callback) { log_callback_ = callback; }

  /// 异步取 bdstoken。[cookie_header] 为凭据原始 Cookie 串（"k=v; k2=v2"），
  /// 会种入 WebView2 Jar 后再导航 disk/main。失败同样回调（errno<0）。
  void GetBdstoken(const std::string& cookie_header, Reply reply);

  /// WinHTTP（Schannel 系统原生栈）同步直取 gettemplatevariable 的用户态
  /// bdstoken——对齐 iOS 第 1 层 URLSession 的「系统网络栈」语义。不依赖
  /// WebView2 运行时、无窗口。入参 [cookie_header] 为凭据 Cookie；先串行
  /// GET www/passport/disk/main 三跳种满 BAIDUID 指纹，再取号。返回 errno
  /// （0=成功），bdstoken/cookie/detail 出参：cookie 为富集后的完整 Cookie
  /// （供 Dart 合并回写凭据），detail 携带 errno/HTTP 状态等关键日志。
  static int FetchBdstokenViaWinHttp(const std::string& cookie_header,
                                     std::string* bdstoken,
                                     std::string* cookie,
                                     std::string* detail);

  /// 释放 WebView2 资源（PlayerPlugin 析构时调用；幂等）。
  void Shutdown();

 private:
  enum class Phase {
    kIdle,
    kCreatingEnv,
    kCreatingCtl,
    kNavigating,
    kSettle,
    kExecuting,
  };

  // WM_TIMER id：1 = 阶段看门狗，2 = 导航完成后 Set-Cookie 沉降。
  static constexpr UINT_PTR kWatchdogTimer = 1;
  static constexpr UINT_PTR kSettleTimer = 2;
  // ProcessFailed 投递消息（回调内只 Post，销毁/回复延后到消息循环执行，
  // 不在 WebView2 回调链内 Close/Release COM 对象）。wparam 携带
  // COREWEBVIEW2_PROCESS_FAILED_KIND。
  static constexpr UINT kProcessFailedMsg = WM_APP + 1;

  void EnsureHostWindow();
  void StartChain();
  // 复用或创建 WebView2 Controller（成功后接 SeedCookies + NavigateMain）。
  // 注意：StartChain / OnEnvironmentCreated 均会调用，必须在头文件声明，
  // 否则 .cpp 中的定义无法成为类成员（CI 曾因漏声明整链报错）。
  void EnsureController();
  // 创建 WebView2 环境（use_fixed=true 用校验通过的固定版目录，否则系统
  // Evergreen）。StartChain 与固定版失败重试共用；失败统一交
  // HandleEnvCreateFailure 处理。
  void BeginCreateEnvironment(bool use_fixed);
  // 环境创建失败处理（[where] 标注环节：同步/回调，供日志区分）：
  // 固定版失败且未重试过 → 自动改用系统 Evergreen 重试一次（对齐 iOS
  // 「系统浏览器永远可用」）；重试过或本就 Evergreen → 如实 FailAll。
  void HandleEnvCreateFailure(HRESULT hr, const char* where);
  void EnterPhase(Phase phase, const char* label, UINT watchdog_ms);
  void NavigateMain();
  void SeedCookies();
  void RunScript();
  // 作废当前 WebView2 会话（进程异常后禁止复用僵尸 COM 对象）。
  void InvalidateSession();
  void OnEnvironmentCreated(HRESULT result, ICoreWebView2Environment* created);
  void OnControllerCreated(HRESULT result, ICoreWebView2Controller* created);
  void OnNavigationCompleted(int generation, bool succeeded);
  // ProcessFailed 延迟处理（HostWndProc kProcessFailedMsg 分发，kind 为
  // COREWEBVIEW2_PROCESS_FAILED_KIND）。
  void OnProcessFailed(DWORD kind);
  void OnWatchdog();
  void OnSettle();
  void OnScriptResult(const std::string& js_return_json);
  void FetchJarCookiesThenComplete(const std::string& token);
  void CompleteAll(int errno_code, const std::string& token,
                   const std::string& cookie, const std::string& message);
  void FailAll(const std::string& message);
  // 原生日志上报：转发到 log_callback_（未挂接则静默丢弃）。
  void EmitLog(const std::string& level, const std::string& message);
  static LRESULT CALLBACK HostWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                      LPARAM lparam);

  HWND parent_window_ = nullptr;
  // 原生日志回调（SetLogCallback 挂接；见 EmitLog）。
  LogCallback log_callback_;
  HWND host_window_ = nullptr;
  Phase phase_ = Phase::kIdle;
  const char* phase_label_ = "";

  // 并发请求队列：CompleteAll / FailAll 逐个回复后清空。
  std::vector<Reply> pending_;
  // 本次链路使用的凭据 Cookie（首个待答复请求的入参）。
  std::string cookie_header_;
  // errno!=0 重试标记：种 Cookie + 重导航仅补一次，防止死循环。
  bool seed_retry_done_ = false;
  // 导航看门狗超时抢救标记：NavigationCompleted 因渲染器遮挡/节流未触发时
  // （云电脑/虚拟显卡实测），跳过事件直接页面 fetch 抢救一次即不再重复，
  // 防止「抢救失败 → 种 Cookie 重导航 → 再超时再抢救」死循环。
  bool nav_salvage_done_ = false;
  // 上次取号是否成功（成功 → 下次走免导航快速路径）。
  bool last_fetch_ok_ = false;
  bool com_initialized_ = false;
  bool shutting_down_ = false;
  // 导航代际：每次 NavigateMain 递增并随回调闭包携带；旧链路遗留的
  // 导航取消事件（如看门狗超时未停的挂起导航在新链路 Navigate 时补发）
  // 因代际不符被忽略——修复「超时挂起后点重试被旧事件秒杀为
  // 网络/风控页失败」。
  int nav_generation_ = 0;
  // 脚本代际：每次 RunScript 递增；旧链路迟到的 ExecuteScript 结果
  // 被忽略，防止跨链路串扰（把上一轮结果答复给当前等待者）。
  int script_generation_ = 0;
  // nav_token_ 是否属于当前 webview_ 实例（导航回调按次重注册时记账，
  // 会话作废后旧 token 随 webview 一起失效，不可再用于 remove）。
  bool nav_registered_ = false;

  // WebView2 运行时选择（3.1859）：固定版目录仅在校验通过时使用（完整性
  // 三级校验见 WebView2BrowserExecutableDir）；校验未通过或环境创建失败时
  // 进程级回退系统 Evergreen，evergreen_retry_used_ 防止来回重试死循环。
  std::wstring fixed_runtime_dir_;
  bool use_fixed_runtime_ = false;
  bool evergreen_retry_used_ = false;

  Microsoft::WRL::ComPtr<ICoreWebView2Environment> env_;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller_;
  Microsoft::WRL::ComPtr<ICoreWebView2> webview_;
  // 事件注册 token（nav 按次重注册携带代际，见 NavigateMain；proc/win 常驻，
  // 随 webview_ 实例一起失效）。
  EventRegistrationToken nav_token_{};
  EventRegistrationToken proc_token_{};
  EventRegistrationToken win_token_{};
};

}  // namespace vbox

#endif  // RUNNER_BAIDU_TOKEN_BRIDGE_H_
