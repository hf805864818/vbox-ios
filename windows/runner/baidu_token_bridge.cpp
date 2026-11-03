//  baidu_token_bridge.cpp
//  Runner
//
//  实现（设计见 baidu_token_bridge.h）。
//
//  取号链路（状态机，全在平台线程）：
//    GetBdstoken → [快速路径] webview 就绪且上次成功 → RunScript
//                → [完整链路] 隐藏窗口/环境/Controller → 种凭据 Cookie
//                  → 导航 disk/main → 沉降 800ms → 页面 fetch gettemplatevariable
//                  → 解析 → Jar Cookie 全量回传
//  失败语义：所有阶段有看门狗；errno!=0 时「种 Cookie + 重导航」仅补一次，
//  之后如实回传 errno 交 Dart 兜底链继续（保存值/重扫码提示）。

#include "baidu_token_bridge.h"

#include <objbase.h>
#include <shellapi.h>
#include <shlobj.h>
#include <winhttp.h>
#include <wrl/event.h>

#include <algorithm>
#include <array>
#include <cstdlib>
#include <iomanip>
#include <regex>
#include <sstream>
#include <utility>

namespace vbox {
namespace {

// ─────────────── 宽窄转换 ───────────────

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                         static_cast<int>(text.size()),
                                         nullptr, 0);
  std::wstring out(static_cast<size_t>(std::max(size, 0)), L'\0');
  if (size > 0) {
    ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                          out.data(), size);
  }
  return out;
}

std::string WideToUtf8(const wchar_t* text) {
  if (text == nullptr || *text == L'\0') return std::string();
  const int bytes = ::WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0,
                                          nullptr, nullptr);
  if (bytes <= 1) return std::string();
  std::string out(static_cast<size_t>(bytes) - 1, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), bytes, nullptr,
                        nullptr);
  return out;
}

// HRESULT → "0x" + 大写十六进制。修复旧代码「"0x" + std::to_string(decimal)」
// 的打印 bug：std::to_string 输出十进制却被拼在 0x 前缀后，导致错误码被误读
// （如 0x80070002 被打印成 0x2147942402，排查方向完全跑偏）。
std::string HexHResult(HRESULT hr) {
  std::ostringstream oss;
  oss << "0x" << std::uppercase << std::hex
      << static_cast<unsigned long>(hr);
  return oss.str();
}

// ─────────────── 极简 JSON 工具（仅处理固定形状的响应） ───────────────

// 解码 ExecuteScript 返回的 JSON 字符串字面量（外层）→ 原始 JS 字符串。
std::string DecodeJsonStringLiteral(const std::string& encoded) {
  const size_t begin = encoded.find('"');
  if (begin == std::string::npos) return encoded;
  std::string out;
  out.reserve(encoded.size());
  for (size_t i = begin + 1; i < encoded.size(); ++i) {
    const char c = encoded[i];
    if (c == '"') break;
    if (c != '\\') {
      out.push_back(c);
      continue;
    }
    if (++i >= encoded.size()) break;
    switch (encoded[i]) {
      case '"': out.push_back('"'); break;
      case '\\': out.push_back('\\'); break;
      case '/': out.push_back('/'); break;
      case 'n': out.push_back('\n'); break;
      case 't': out.push_back('\t'); break;
      case 'r': out.push_back('\r'); break;
      case 'b': out.push_back('\b'); break;
      case 'f': out.push_back('\f'); break;
      case 'u': {
        // 响应字段均为 ASCII（bdstoken 为 32 位十六进制 / errno 数字），
        // 非 BMP 转义直接跳过 4 位十六进制（保底不崩）。
        i += std::min<size_t>(4, encoded.size() - i - 1);
        out.push_back('?');
        break;
      }
      default: out.push_back(encoded[i]); break;
    }
  }
  return out;
}

// 取 "key":"value"（仅 ASCII 值场景：bdstoken / pageToken）。
std::string FindJsonStringValue(const std::string& json, const char* key) {
  std::string needle = std::string("\"") + key + "\":";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) {
    needle = std::string("\"") + key + "\" :";
    pos = json.find(needle);
  }
  if (pos == std::string::npos) return std::string();
  pos += needle.size();
  while (pos < json.size() && json[pos] == ' ') ++pos;
  if (pos >= json.size() || json[pos] != '"') return std::string();
  const std::string raw = DecodeJsonStringLiteral(json.substr(pos));
  return raw;
}

int FindJsonIntValue(const std::string& json, const char* key, int fallback) {
  std::string needle = std::string("\"") + key + "\":";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) {
    needle = std::string("\"") + key + "\" :";
    pos = json.find(needle);
  }
  if (pos == std::string::npos) return fallback;
  pos += needle.size();
  const size_t digits_begin = json.find_first_of("-0123456789", pos);
  if (digits_begin == std::string::npos) return fallback;
  try {
    return std::stoi(json.substr(digits_begin));
  } catch (...) {
    return fallback;
  }
}

// 解析凭据 Cookie 头（"k=v; k2=v2"）→ 名值对（k/v 为 UTF-8）。
std::vector<std::pair<std::string, std::string>> ParseCookieHeader(
    const std::string& header) {
  std::vector<std::pair<std::string, std::string>> pairs;
  size_t pos = 0;
  while (pos < header.size()) {
    const size_t semi = header.find(';', pos);
    const std::string piece = header.substr(
        pos, semi == std::string::npos ? std::string::npos : semi - pos);
    pos = semi == std::string::npos ? header.size() : semi + 1;
    const size_t eq = piece.find('=');
    if (eq == std::string::npos || eq == 0) continue;
    std::string name = piece.substr(0, eq);
    std::string value = piece.substr(eq + 1);
    const auto trim = [](std::string& s) {
      const auto not_space = [](unsigned char ch) { return ch > ' '; };
      s.erase(s.begin(), std::find_if(s.begin(), s.end(), not_space));
      s.erase(std::find_if(s.rbegin(), s.rend(), not_space).base(), s.end());
    };
    trim(name);
    trim(value);
    if (!name.empty()) pairs.emplace_back(std::move(name), std::move(value));
  }
  return pairs;
}

// 递归建目录（存在即成功）。
void EnsureDirectory(const std::wstring& dir) {
  std::wstring built;
  for (size_t i = 0; i < dir.size(); ++i) {
    built.push_back(dir[i]);
    if (dir[i] == L'\\' && built.size() > 3) {
      ::CreateDirectoryW(built.c_str(), nullptr);
    }
  }
  ::CreateDirectoryW(dir.c_str(), nullptr);
}

std::wstring WebView2UserDataDir() {
  PWSTR roaming = nullptr;
  std::wstring dir;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                       &roaming)) &&
      roaming != nullptr) {
    dir = std::wstring(roaming) + L"\\com.vbox\\vbox\\win_baidu_webview";
    ::CoTaskMemFree(roaming);
  }
  if (!dir.empty()) EnsureDirectory(dir);
  return dir;
}

// 解析 "a.b.c.d" 版本串前三段（major.minor.build）；段缺失/非法记 0。
std::array<int, 3> ParseVersionPrefix3(const std::string& version) {
  std::array<int, 3> out{0, 0, 0};
  size_t begin = 0;
  for (int i = 0; i < 3; ++i) {
    if (begin > version.size()) break;
    const size_t end = version.find('.', begin);
    const std::string seg = version.substr(
        begin, end == std::string::npos ? std::string::npos : end - begin);
    try {
      out[i] = std::stoi(seg);
    } catch (...) {
      out[i] = 0;
    }
    if (end == std::string::npos) break;
    begin = end + 1;
  }
  return out;
}

// 读 PE 文件的 VERSIONINFO FileVersion（"a.b.c.d"），失败返回空串。
std::string QueryFileVersion(const std::wstring& file) {
  DWORD handle = 0;
  const DWORD size = ::GetFileVersionInfoSizeW(file.c_str(), &handle);
  if (size == 0) return std::string();
  std::vector<BYTE> data(size);
  if (!::GetFileVersionInfoW(file.c_str(), 0, size, data.data())) {
    return std::string();
  }
  VS_FIXEDFILEINFO* info = nullptr;
  UINT len = 0;
  if (!::VerQueryValueW(data.data(), L"\\", reinterpret_cast<LPVOID*>(&info),
                        &len) ||
      info == nullptr || len < sizeof(VS_FIXEDFILEINFO)) {
    return std::string();
  }
  std::ostringstream oss;
  oss << HIWORD(info->dwFileVersionMS) << "." << LOWORD(info->dwFileVersionMS)
      << "." << HIWORD(info->dwFileVersionLS) << "."
      << LOWORD(info->dwFileVersionLS);
  return oss.str();
}

// 随包内置的 WebView2 固定版（Fixed Version）运行时目录：<exeDir>\webview2。
// 校验通过则返回该目录，供 CreateCoreWebView2EnvironmentWithOptions 第一参
// browserExecutableFolder 离线加载——不依赖系统是否安装 Edge WebView2
// Evergreen 运行时（「WebView2 运行时不可用」= 系统未装 Evergreen 的根因，
// 3.1857 起打包脚本 bundle-webview2-windows.ps1 将固定版随安装包分发，
// installer.iss 递归打包 Release\webview2\* 自动携带）。
//
// 3.1859 加固：仅「exe 存在」不再视为可用——云电脑实测该目录 142/155 文件
// 混杂时环境创建虽成功、导航却无响应（25s 看门狗超时）。改为三级完整性
// 校验，任一不过返回空串并回退系统 Evergreen：
//   级 1：GetAvailableCoreWebView2BrowserVersionString(runtime) 能从该目录
//         探测出非空运行时版本（加载器可加载该目录）；
//   级 2：exe 的 VERSIONINFO FileVersion 与探测版本前三段一致；
//   级 3：核心 dll（msedgewebview2.dll）版本与 exe 前三段一致——直接抓
//         「exe 与核心 dll 版本错配」的混杂目录（本机实测主症状）。
// [reject_reason] 出参约定：返回空串时，空 = 目录不存在（未检测到，非完整
// 性问题）；非空 = 存在但校验拒绝（拒绝原因，供日志留痕）。
std::wstring WebView2BrowserExecutableDir(std::string* reject_reason) {
  if (reject_reason != nullptr) reject_reason->clear();
  wchar_t path[MAX_PATH] = {0};
  const DWORD len = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    if (reject_reason != nullptr) *reject_reason = "宿主 exe 路径获取失败";
    return std::wstring();
  }
  std::wstring dir(path);
  const size_t slash = dir.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    if (reject_reason != nullptr) *reject_reason = "宿主 exe 路径异常";
    return std::wstring();
  }
  dir.resize(slash);
  const std::wstring runtime = dir + L"\\webview2";
  const std::wstring exe = runtime + L"\\msedgewebview2.exe";
  const DWORD attr = ::GetFileAttributesW(exe.c_str());
  if (attr == INVALID_FILE_ATTRIBUTES || (attr & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    return std::wstring();  // 目录不存在：reason 留空 = 未检测到。
  }
  // 级 1：加载器探测——能从固定版目录解析出可用运行时版本。
  LPWSTR detected = nullptr;
  const HRESULT vr = ::GetAvailableCoreWebView2BrowserVersionString(
      runtime.c_str(), &detected);
  if (FAILED(vr) || detected == nullptr || *detected == L'\0') {
    if (reject_reason != nullptr) {
      *reject_reason = "运行时探测失败（hr=" + HexHResult(vr) + "）";
    }
    if (detected != nullptr) ::CoTaskMemFree(detected);
    return std::wstring();
  }
  const std::string detected_version = WideToUtf8(detected);
  ::CoTaskMemFree(detected);
  // 级 2：exe 文件版本与探测版本前三段比对。
  const std::string exe_version = QueryFileVersion(exe);
  if (exe_version.empty()) {
    if (reject_reason != nullptr) *reject_reason = "exe 版本信息缺失";
    return std::wstring();
  }
  // 级 3：核心 dll 版本与 exe 比对（防 142/155 混杂错配）。
  const std::string core_dll_version =
      QueryFileVersion(runtime + L"\\msedgewebview2.dll");
  if (core_dll_version.empty()) {
    if (reject_reason != nullptr) *reject_reason = "核心 dll 缺失版本信息";
    return std::wstring();
  }
  if (ParseVersionPrefix3(exe_version) != ParseVersionPrefix3(detected_version) ||
      ParseVersionPrefix3(core_dll_version) != ParseVersionPrefix3(exe_version)) {
    if (reject_reason != nullptr) {
      *reject_reason = "版本错配（exe=" + exe_version + "，核心dll=" +
                       core_dll_version + "，探测=" + detected_version +
                       "，疑似混杂目录）";
    }
    return std::wstring();
  }
  return runtime;
}

// 页面上下文取号脚本：disk/main 同源 fetch（credentials 自动携带 Jar 全量
// Cookie，含服务端现场补种的指纹字段），返回 JSON 字符串交原生解析。
constexpr const char* kBdstokenJs = R"js((async function(){
  try {
    var r = await fetch('https://pan.baidu.com/api/gettemplatevariable?app_id=250528&clienttype=0&web=1&fields=%5B%22bdstoken%22%5D', {credentials:'include'});
    var t = await r.text();
    var pageToken = '';
    try { if (window.locals && window.locals.get) pageToken = window.locals.get('bdstoken') || ''; } catch (e) {}
    try { if (!pageToken && window.yunData && window.yunData.MYBDSTOKEN) pageToken = window.yunData.MYBDSTOKEN; } catch (e) {}
    var docCookie = '';
    try { docCookie = document.cookie || ''; } catch (e) {}
    return JSON.stringify({httpOk: r.ok, status: r.status, body: t, pageToken: pageToken, docCookie: docCookie});
  } catch (e) {
    return JSON.stringify({httpOk: false, err: String(e)});
  }
})())js";

std::string Excerpt(const std::string& text, size_t keep) {
  if (text.size() <= keep) return text;
  return text.substr(0, keep) + "…";
}

// 常态停靠位（取号窗口常态位）：主窗口客户区右下角内侧 2x2（对齐 iOS
// BaiduWebViewBridge「1x1 WKWebView addSubview 到可见 key window」）。
//
// 3.1854 曾用「虚拟屏外 +64px」：Win32 IsWindowVisible=TRUE、Controller
// IsVisible=TRUE，但 Chromium 的 NativeWindowOcclusionTracker 会把
// 「完全不在任何显示器区域内」的窗口判定为 hidden/occluded → WebView2
// 照样挂起渲染、NavigationCompleted 不触发 → 25s 看门狗超时照旧
// （3.1855 云电脑实测仍超时的根因）。挂在主窗口客户区内则窗口几何上
// 位于屏幕内且 owned 弹窗永远在 owner 之上（2 像素不被主窗口遮挡），
// occlusion 判定可见，导航/JS 正常执行；配合 WS_EX_TRANSPARENT 鼠标
// 穿透 + WS_EX_NOACTIVATE + WS_EX_TOOLWINDOW，用户完全无感。
POINT InWindowDockPosition(HWND parent_window) {
  const int kSize = 2;
  if (parent_window != nullptr && ::IsWindow(parent_window)) {
    RECT client{};
    POINT origin{0, 0};
    if (::GetClientRect(parent_window, &client) &&
        ::ClientToScreen(parent_window, &origin)) {
      const int right = origin.x + static_cast<int>(client.right);
      const int bottom = origin.y + static_cast<int>(client.bottom);
      return POINT{right - kSize, bottom - kSize};
    }
  }
  // 兜底：主窗口不可用（理论不发生——桥由插件持有 parent）时退回
  // 主显示器右下角内侧（仍在屏幕内，保住「几何可见」语义）。
  const int sw = ::GetSystemMetrics(SM_CXSCREEN);
  const int sh = ::GetSystemMetrics(SM_CYSCREEN);
  return POINT{sw - kSize - 8, sh - kSize - 8};
}

// 构造通道结果 EncodableValue（GetBdstoken 前置声明使用，置于匿名命名空间）。
flutter::EncodableValue BuildResult(int errno_code, const std::string& token,
                                    const std::string& cookie,
                                    const std::string& message) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("errno")] = flutter::EncodableValue(errno_code);
  map[flutter::EncodableValue("bdstoken")] = flutter::EncodableValue(token);
  map[flutter::EncodableValue("cookie")] = flutter::EncodableValue(cookie);
  map[flutter::EncodableValue("message")] = flutter::EncodableValue(message);
  return flutter::EncodableValue(std::move(map));
}

// WinHTTP 统一浏览器 UA（三跳种码与取号请求共用，对齐 Dart 第 1 层）。
const wchar_t kWinHttpUserAgent[] =
    L"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    L"(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

// WinHTTP 单跳只读 GET（种 BAIDUID 指纹）。合并本跳响应 Set-Cookie 到
// [cookie_inout]（作为下一跳 / 取号请求的 Cookie 头）。返回 HTTP 状态码
// （失败返回 0；Set-Cookie 收集与否不影响取号链路成败——种码只读端点）。
int WinHttpSeedHop(const std::wstring& host, const std::wstring& path,
                   std::string* cookie_inout) {
  const auto ascii_lower = [](wchar_t c) -> wchar_t {
    return (c >= L'A' && c <= L'Z') ? c + (L'a' - L'A') : c;
  };
  const auto header_is_set_cookie = [&](const std::wstring& line) -> bool {
    if (line.size() <= 10) return false;
    if (line[10] != L':') return false;  // "Set-Cookie" 长度 10
    for (size_t i = 0; i < 10; ++i) {
      if (ascii_lower(line[i]) != L"set-cookie"[i]) return false;
    }
    return true;
  };

  HINTERNET session = ::WinHttpOpen(
      kWinHttpUserAgent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (session == nullptr) return 0;
  ::WinHttpSetTimeouts(session, 0, 5000, 5000, 8000);
  HINTERNET connect = ::WinHttpConnect(session, host.c_str(),
                                       INTERNET_DEFAULT_HTTPS_PORT, 0);
  if (connect == nullptr) {
    ::WinHttpCloseHandle(session);
    return 0;
  }
  HINTERNET request = ::WinHttpOpenRequest(
      connect, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER,
      WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
  if (request == nullptr) {
    ::WinHttpCloseHandle(connect);
    ::WinHttpCloseHandle(session);
    return 0;
  }
  if (!cookie_inout->empty()) {
    const std::wstring headers =
        L"Cookie: " + Utf8ToWide(*cookie_inout) +
        L"\r\nAccept: text/html,application/xhtml+xml,"
        L"application/xml;q=0.9,*/*;q=0.8";
    ::WinHttpAddRequestHeaders(request, headers.c_str(),
                               static_cast<DWORD>(headers.size()),
                               WINHTTP_ADDREQ_FLAG_ADD);
  }
  if (!::WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
      !::WinHttpReceiveResponse(request, nullptr)) {
    ::WinHttpCloseHandle(request);
    ::WinHttpCloseHandle(connect);
    ::WinHttpCloseHandle(session);
    return 0;
  }
  DWORD status = 0;
  DWORD status_size = sizeof(status);
  ::WinHttpQueryHeaders(request,
                        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size,
                        WINHTTP_NO_HEADER_INDEX);
  // 全量响应头逐行解析 Set-Cookie（RAW_HEADERS_CRLF 含状态行 + 各头部行）。
  DWORD raw_size = 0;
  ::WinHttpQueryHeaders(request, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                        WINHTTP_HEADER_NAME_BY_INDEX, nullptr, &raw_size,
                        WINHTTP_NO_HEADER_INDEX);
  if (raw_size > sizeof(wchar_t)) {
    std::vector<wchar_t> raw(raw_size / sizeof(wchar_t) + 1);
    if (::WinHttpQueryHeaders(request, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                              WINHTTP_HEADER_NAME_BY_INDEX, raw.data(),
                              &raw_size, WINHTTP_NO_HEADER_INDEX)) {
      const std::wstring block(raw.data(), raw_size / sizeof(wchar_t));
      std::string merged;
      size_t pos = 0;
      while (pos < block.size()) {
        const size_t nl = block.find(L"\r\n", pos);
        const std::wstring line =
            block.substr(pos, nl == std::wstring::npos ? std::wstring::npos
                                                       : nl - pos);
        pos = nl == std::wstring::npos ? block.size() : nl + 2;
        if (!header_is_set_cookie(line)) continue;
        std::wstring val = line.substr(11);  // 跳过 "Set-Cookie:"
        while (!val.empty() && val.front() == L' ') val.erase(val.begin());
        const size_t semi = val.find(L';');
        if (semi != std::wstring::npos) val = val.substr(0, semi);
        const std::string pair = WideToUtf8(val.c_str());
        if (pair.find('=') != std::string::npos) {
          if (!merged.empty()) merged += "; ";
          merged += pair;
        }
      }
      if (!merged.empty()) {
        if (cookie_inout->empty()) {
          *cookie_inout = merged;
        } else {
          *cookie_inout = *cookie_inout + "; " + merged;
        }
      }
    }
  }
  ::WinHttpCloseHandle(request);
  ::WinHttpCloseHandle(connect);
  ::WinHttpCloseHandle(session);
  return static_cast<int>(status);
}

}  // namespace

// ─────────────── 生命周期 ───────────────

BaiduTokenBridge::BaiduTokenBridge(HWND parent_window)
    : parent_window_(parent_window) {}

BaiduTokenBridge::~BaiduTokenBridge() { Shutdown(); }

void BaiduTokenBridge::Shutdown() {
  shutting_down_ = true;
  if (host_window_ != nullptr) {
    ::KillTimer(host_window_, kWatchdogTimer);
    ::KillTimer(host_window_, kSettleTimer);
  }
  InvalidateSession();
  env_.Reset();
  if (host_window_ != nullptr) {
    ::SetWindowLongPtrW(host_window_, GWLP_USERDATA, 0);
    ::DestroyWindow(host_window_);
    host_window_ = nullptr;
  }
  FailAll("桥已关闭");
}

// 作废当前 WebView2 会话：关闭并释放 Controller / WebView。
//
// 调用点：Shutdown（析构）与 ProcessFailed（进程异常）。
// 关键语义：渲染/浏览器进程死亡后，controller_ / webview_ 指向的 COM 对象
// 已是僵尸——若仍非空，下次调用 EnsureController 会直接复用它们，
// SeedCookies / Navigate 打在死对象上 → 原生崩溃（点重试闪退的根因）。
// 作废后 EnsureController 走全新创建路径。
void BaiduTokenBridge::InvalidateSession() {
  if (controller_ != nullptr) {
    controller_->Close();
  }
  webview_.Reset();
  controller_.Reset();
  // 事件 token 随 webview 实例一起失效（新实例上重注册，见 NavigateMain）。
  nav_registered_ = false;
}

// ─────────────── WinHTTP 直取 bdstoken（第 1 层系统栈，对齐 iOS URLSession） ───────────────
//
// 背景：iOS 第 1 层用 URLSession（CFNetwork 系统栈）请求 gettemplatevariable，
// 百度风控信任、一步成功；Windows 上 dart:io HttpClient（BoringSSL）被风控
// （errno=-6），此前全押 WebView2 兜底，而 WebView2 依赖运行时安装与窗口
// 可见性等环境条件，精简系统/云电脑上脆弱。WinHTTP 走 Schannel 系统栈
// （与 Edge/IE 同源），是 Windows 上最接近 URLSession 的等价物：不依赖
// WebView2、无窗口、秒级完成。返回 errno（0=取得 bdstoken），响应关键信息
// 写入 detail 供日志留痕——百度对 Schannel 指纹的信任度由实测 errno 判定
// （0=通过，-6=被风控，届时仍需 WebView2 兜底）。
int BaiduTokenBridge::FetchBdstokenViaWinHttp(const std::string& cookie_header,
                                              std::string* bdstoken,
                                              std::string* cookie,
                                              std::string* detail) {
  *bdstoken = std::string();
  *cookie = std::string();
  // 先三跳种码（www → passport → disk/main）：把 BAIDUID/BAIDUID_BFESS 等
  // 指纹字段种满，再带完整 Cookie 取号——对齐 Dart 层 `_enrichBdstoken` 的
  // 完整会话语义下沉到 Schannel 栈（此前单跳直取缺指纹，被百度风控）。
  std::string merged_cookie = cookie_header;
  const wchar_t* kBaiduSeedHops[][2] = {
      {L"www.baidu.com", L"/"},
      {L"passport.baidu.com", L"/center"},
      {L"pan.baidu.com", L"/disk/main"},
  };
  for (const auto& hop : kBaiduSeedHops) {
    WinHttpSeedHop(hop[0], hop[1], &merged_cookie);
  }
  *cookie = merged_cookie;
  // fields 与 Dart 第 1 层完全一致（已 urlencode）。
  static const wchar_t kPath[] =
      L"/api/gettemplatevariable?clienttype=0&app_id=250528&web=1&bdstoken="
      L"&fields=%5B%22bdstoken%22%2C%22token%22%2C%22uk%22%2C%22isdocuser%22"
      L"%2C%22servertime%22%5D";

  HINTERNET session = nullptr;
  HINTERNET connect = nullptr;
  HINTERNET request = nullptr;
  auto close_all = [&session, &connect, &request]() {
    if (request != nullptr) ::WinHttpCloseHandle(request);
    if (connect != nullptr) ::WinHttpCloseHandle(connect);
    if (session != nullptr) ::WinHttpCloseHandle(session);
  };

  session = ::WinHttpOpen(kWinHttpUserAgent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                          WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (session == nullptr) {
    *detail = "WinHttpOpen 失败（Gle=" + std::to_string(::GetLastError()) + "）";
    close_all();
    return -1;
  }
  // 紧超时（同步调用，平台线程等待）：解析/连接 5s，收发 8s。
  ::WinHttpSetTimeouts(session, 0, 5000, 5000, 8000);
  connect = ::WinHttpConnect(session, L"pan.baidu.com",
                             INTERNET_DEFAULT_HTTPS_PORT, 0);
  if (connect == nullptr) {
    *detail = "WinHttpConnect 失败（Gle=" + std::to_string(::GetLastError()) +
              "）";
    close_all();
    return -1;
  }
  request = ::WinHttpOpenRequest(connect, L"GET", kPath, nullptr,
                                 WINHTTP_NO_REFERER,
                                 WINHTTP_DEFAULT_ACCEPT_TYPES,
                                 WINHTTP_FLAG_SECURE);
  if (request == nullptr) {
    *detail = "WinHttpOpenRequest 失败";
    close_all();
    return -1;
  }
  // 请求头对齐 Dart 第 1 层（Cookie / Referer / Accept；UA 已随 WinHttpOpen）。
  const std::wstring headers =
      L"Cookie: " + Utf8ToWide(merged_cookie) +
      L"\r\nReferer: https://pan.baidu.com/disk/main"
      L"\r\nAccept: application/json, text/plain, */*";
  if (!::WinHttpAddRequestHeaders(
          request, headers.c_str(), static_cast<DWORD>(headers.size()),
          WINHTTP_ADDREQ_FLAG_ADD)) {
    *detail = "WinHttpAddRequestHeaders 失败";
    close_all();
    return -1;
  }
  if (!::WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
      !::WinHttpReceiveResponse(request, nullptr)) {
    const DWORD gle = ::GetLastError();
    *detail = gle == ERROR_WINHTTP_TIMEOUT
                  ? "WinHTTP 请求超时"
                  : "WinHTTP 请求失败（Gle=" + std::to_string(gle) + "）";
    close_all();
    return -1;
  }
  DWORD status = 0;
  DWORD status_size = sizeof(status);
  if (!::WinHttpQueryHeaders(
          request,
          WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
          WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size,
          WINHTTP_NO_HEADER_INDEX)) {
    *detail = "WinHTTP 查询状态码失败";
    close_all();
    return -1;
  }
  std::string body;
  for (;;) {
    DWORD available = 0;
    if (!::WinHttpQueryDataAvailable(request, &available) || available == 0) {
      break;
    }
    std::vector<char> chunk(available);
    DWORD read = 0;
    if (!::WinHttpReadData(request, chunk.data(), available, &read) ||
        read == 0) {
      break;
    }
    body.append(chunk.data(), read);
  }
  close_all();

  if (status != 200) {
    // 3.1862 诊断增强：带出响应体摘要（57 字节级风控响应全文可见，据此
    // 判定拦截类型：风控 JSON / 验证页跳转 / 代理劫持）。
    *detail = "HTTP " + std::to_string(status) + "（body " +
              std::to_string(body.size()) + " 字节：" + Excerpt(body, 160) +
              "）";
    return -1;
  }
  // 容错解析 errno 与 bdstoken（与页面 JSON 的空格无关）。
  std::smatch m;
  int errno_code = -1;
  if (std::regex_search(body, m,
                        std::regex("\"errno\"\\s*:\\s*(-?\\d+)"))) {
    errno_code = std::atoi(m[1].str().c_str());
  }
  if (errno_code == 0 &&
      std::regex_search(body, m,
                        std::regex("\"bdstoken\"\\s*:\\s*\"([^\"]+)\""))) {
    *bdstoken = m[1].str();
    *detail = "WinHTTP errno=0，取得 bdstoken";
    return 0;
  }
  *detail = "WinHTTP errno=" + std::to_string(errno_code) + "（body " +
            std::to_string(body.size()) + " 字节：" + Excerpt(body, 160) +
            "）";
  return errno_code != 0 ? errno_code : -1;
}

void BaiduTokenBridge::EnsureHostWindow() {
  // 主窗口移动/缩放后常态位会漂移：每条链路开始时刷新停靠位，保持
  // 「主窗口客户区内 2x2」几何可见语义（见 InWindowDockPosition 注释）。
  const POINT dock = InWindowDockPosition(parent_window_);
  if (host_window_ != nullptr) {
    ::SetWindowPos(host_window_, nullptr, dock.x, dock.y, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOZORDER);
    return;
  }

  static const wchar_t* kClass = L"VboxWebView2Host";
  static bool class_registered = false;
  if (!class_registered) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = HostWndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = kClass;
    if (::RegisterClassExW(&wc) == 0 && ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return;
    }
    class_registered = true;
  }
  // 主窗口客户区内的 owned 弹出窗口（2x2，右下角内侧）：SW_SHOWNOACTIVATE
  // 显示（不抢焦点），TRANSPARENT 鼠标穿透、TOOLWINDOW 不进任务栏——用户
  // 无感，但窗口几何在屏幕内且位于 owner 之上，Chromium occlusion 判定
  // 「可见」，导航/页面 JS 正常执行——这是取号链能否工作的关键（隐藏/
  // IsVisible=FALSE/虚拟屏外都会被判定 hidden → NavigationCompleted
  // 挂起 → 25s 必超时；对齐 iOS「1x1 WKWebView 挂可见 window」）。
  host_window_ = ::CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT, kClass,
      L"vbox-webview2-host", WS_POPUP, dock.x, dock.y, 2, 2, parent_window_,
      nullptr, ::GetModuleHandleW(nullptr), nullptr);
  if (host_window_ != nullptr) {
    ::SetWindowLongPtrW(host_window_, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(this));
    ::ShowWindow(host_window_, SW_SHOWNOACTIVATE);
  }
}

LRESULT CALLBACK BaiduTokenBridge::HostWndProc(HWND hwnd, UINT msg,
                                               WPARAM wparam, LPARAM lparam) {
  if (msg == WM_TIMER) {
    auto* bridge = reinterpret_cast<BaiduTokenBridge*>(
        ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (bridge != nullptr) {
      if (wparam == kWatchdogTimer) {
        bridge->OnWatchdog();
        return 0;
      }
      if (wparam == kSettleTimer) {
        bridge->OnSettle();
        return 0;
      }
    }
  }
  if (msg == kProcessFailedMsg) {
    // ProcessFailed 回调投递的延迟处理（见 OnControllerCreated 注册处注释）。
    auto* bridge = reinterpret_cast<BaiduTokenBridge*>(
        ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (bridge != nullptr) {
      bridge->OnProcessFailed(static_cast<DWORD>(wparam));
      return 0;
    }
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

void BaiduTokenBridge::OnProcessFailed(DWORD kind) {
  last_fetch_ok_ = false;
  InvalidateSession();
  // 浏览器主进程死亡时环境一并作废，下次调用从建环境开始。
  if (kind == COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED) {
    env_.Reset();
  }
  if (phase_ != Phase::kIdle) {
    FailAll("WebView2 进程异常退出（会话已作废，下次调用自动重建）");
  }
}

// ─────────────── 取号入口 ───────────────

void BaiduTokenBridge::GetBdstoken(const std::string& cookie_header,
                                   Reply reply) {
  EmitLog("info", std::string("百度取号：cookie 长度=") +
                      std::to_string(cookie_header.size()) +
                      (last_fetch_ok_ ? "，上次已成功" : ""));
  if (shutting_down_) {
    EmitLog("warn", "百度取号：桥已关闭，直接拒绝");
    reply(BuildResult(-1, std::string(), std::string(), "桥已关闭"));
    return;
  }
  pending_.push_back(std::move(reply));
  if (phase_ != Phase::kIdle) {
    // 已有链路在跑：结果出来后一并答复（调用方串行触发，实际不会发生）。
    EmitLog("debug", "百度取号：已有链路在跑，本次请求并入等待队列");
    return;
  }
  cookie_header_ = cookie_header;
  seed_retry_done_ = false;
  nav_salvage_done_ = false;

  if (webview_ && last_fetch_ok_) {
    // 快速路径：页面会话已就绪（Jar/登录态都在），免导航直接 fetch。
    EmitLog("info", "百度取号：会话已就绪，走免导航快速路径直接页面 fetch");
    EnterPhase(Phase::kExecuting, "页面fetch", 15000);
    RunScript();
    return;
  }
  EmitLog("info", "百度取号：启动完整链路（建环境→建控制器→种 Cookie→导航）");
  StartChain();
}

void BaiduTokenBridge::CompleteAll(int errno_code, const std::string& token,
                                   const std::string& cookie,
                                   const std::string& message) {
  if (host_window_ != nullptr) {
    ::KillTimer(host_window_, kWatchdogTimer);
    ::KillTimer(host_window_, kSettleTimer);
  }
  phase_ = Phase::kIdle;
  phase_label_ = "";
  flutter::EncodableValue value =
      BuildResult(errno_code, token, cookie, message);
  std::vector<Reply> replies;
  replies.swap(pending_);
  for (auto& reply : replies) {
    reply(value);
  }
}

void BaiduTokenBridge::FailAll(const std::string& message) {
  CompleteAll(-1, std::string(), std::string(), message);
}

void BaiduTokenBridge::EmitLog(const std::string& level,
                               const std::string& message) {
  if (log_callback_) {
    log_callback_(level, message);
  }
}

void BaiduTokenBridge::EnterPhase(Phase phase, const char* label,
                                  UINT watchdog_ms) {
  phase_ = phase;
  phase_label_ = label;
  if (host_window_ != nullptr) {
    if (watchdog_ms > 0) {
      ::SetTimer(host_window_, kWatchdogTimer, watchdog_ms, nullptr);
    } else {
      ::KillTimer(host_window_, kWatchdogTimer);
    }
  }
}

void BaiduTokenBridge::OnWatchdog() {
  ::KillTimer(host_window_, kWatchdogTimer);
  // 导航看门狗超时（非交互）：页面可能已就绪、只是 NavigationCompleted 因
  // 渲染器遮挡/节流未触发（云电脑/虚拟显卡实测——有网、页面已加载，但完成
  // 事件迟迟不发）。此时不必等事件，直接页面 fetch 抢救一次：页面 JS 上下文
  // 通常已可用，同源 fetch 取下 bdstoken 即自动取号，免去「点重试」人工步骤。
  // 仅一次（nav_salvage_done_）：若页面确未加载（fetch 失败），才走后续
  // 种 Cookie 重导航 / 如实报错，避免无限自抢救。
  if (webview_ != nullptr && phase_ == Phase::kNavigating &&
      !nav_salvage_done_) {
    nav_salvage_done_ = true;
    EmitLog("warn", "导航超时：跳过 NavigationCompleted，直接页面 fetch 抢救");
    EnterPhase(Phase::kExecuting, "页面fetch", 15000);
    RunScript();
    return;
  }
  // 停掉仍在飞行的导航：导航挂起超时后 WebView2 内并未停止，若不停掉，
  // 旧导航的取消事件会在下一条链路 Navigate 时补发——即使有代际校验，
  // 也让它彻底结束（双保险）。
  if (webview_ != nullptr && phase_ == Phase::kNavigating) {
    webview_->Stop();
  }
  // 3.1859 兜底：本次链路用的是固定版却走到看门狗超时（混杂目录可能
  // 「环境创建成功但导航无响应」，完整性校验不一定拦得住）→ 标记回退，
  // 下次链路跳过固定版直接走系统 Evergreen。回退过或本就 Evergreen 时无操作。
  if (use_fixed_runtime_) {
    evergreen_retry_used_ = true;
    EmitLog("warn", "固定版链路看门狗超时，下次取号将跳过固定版走系统 Evergreen");
  }
  FailAll(std::string("取号阶段超时（") + (phase_label_ ? phase_label_ : "?") +
          "）");
}

// ─────────────── 完整链路 ───────────────

// 创建 WebView2 环境（StartChain 与固定版失败重试共用）。use_fixed=true 用
// 校验通过的固定版目录离线加载，否则系统 Evergreen。同步失败转
// HandleEnvCreateFailure（回调失败由 OnEnvironmentCreated 转入）。
void BaiduTokenBridge::BeginCreateEnvironment(bool use_fixed) {
  EnterPhase(Phase::kCreatingEnv, "创建WebView2环境", 20000);
  auto handler = Microsoft::WRL::Callback<
      ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
      [this](HRESULT result, ICoreWebView2Environment* created) -> HRESULT {
        OnEnvironmentCreated(result, created);
        return S_OK;
      });
  const HRESULT hr = ::CreateCoreWebView2EnvironmentWithOptions(
      use_fixed ? fixed_runtime_dir_.c_str() : nullptr,
      WebView2UserDataDir().c_str(), nullptr, handler.Get());
  if (FAILED(hr)) {
    HandleEnvCreateFailure(hr, "同步");
  }
}

// 环境创建失败统一处理：当前用固定版且未回退过 → 置回退标记后改用系统
// Evergreen 重试一次（固定版混杂/损坏时系统运行时仍可用——本机实测主场景）；
// 本就 Evergreen 或已回退过 → 如实终止本次链路。
void BaiduTokenBridge::HandleEnvCreateFailure(HRESULT hr, const char* where) {
  if (use_fixed_runtime_ && !evergreen_retry_used_) {
    evergreen_retry_used_ = true;
    EmitLog("error", std::string("WebView2 固定版环境创建失败（") + where +
                         " hr=" + HexHResult(hr) + "），回退系统 Evergreen 重试");
    use_fixed_runtime_ = false;
    LPWSTR version = nullptr;
    const HRESULT vr = ::GetAvailableCoreWebView2BrowserVersionString(
        nullptr, &version);
    if (FAILED(vr) || version == nullptr) {
      EmitLog("error", "系统 Evergreen WebView2 运行时也不可用（hr=" +
                           HexHResult(vr) + "），无可用运行时");
      FailAll("WebView2 运行时不可用（固定版创建失败 + Evergreen 缺失，hr=" +
              HexHResult(vr) + "）");
      return;
    }
    ::CoTaskMemFree(version);
    EmitLog("info", "系统 Evergreen WebView2 运行时已检测到，开始重试");
    BeginCreateEnvironment(false);
    return;
  }
  FailAll(std::string("创建 WebView2 环境失败（") + where +
          " hr=" + HexHResult(hr) + "）");
}

void BaiduTokenBridge::StartChain() {
  EnsureHostWindow();
  if (host_window_ == nullptr) {
    FailAll("WebView2 宿主窗口创建失败");
    return;
  }
  if (!com_initialized_) {
    // Runner 主线程默认已是 STA（Flutter 模板 main.cpp），重复初始化返回
    // S_FALSE/RPC_E_CHANGED_MODE 均可接受。
    const HRESULT hr = ::CoInitializeEx(
        nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    com_initialized_ = SUCCEEDED(hr);
    EmitLog(com_initialized_ ? "debug" : "warn",
            std::string("COM 初始化：") +
                (com_initialized_ ? "成功" : "失败（hr=" + HexHResult(hr) + "）"));
  }
  if (env_ != nullptr) {
    // 环境/控制器常驻复用：直接续链（种 Cookie + 导航）。
    EnsureController();
    return;
  }
  // ── WebView2 运行时选择（3.1859）──
  // 固定版目录经完整性校验通过才使用；校验未通过（目录混杂/版本错配）或
  // 此前环境创建失败已回退过的，进程级走系统 Evergreen（对齐 iOS「系统
  // 浏览器永远可用」）；evergreen_retry_used_ 防固定版↔Evergreen 来回死循环。
  std::string reject_reason;
  fixed_runtime_dir_ = WebView2BrowserExecutableDir(&reject_reason);
  if (!fixed_runtime_dir_.empty()) {
    if (evergreen_retry_used_) {
      use_fixed_runtime_ = false;
      EmitLog("warn",
              "WebView2 固定版校验通过，但此前环境创建失败已回退，本次仍走系统 Evergreen");
    } else {
      use_fixed_runtime_ = true;
      EmitLog("info", "WebView2 固定版运行时完整性校验通过：" +
                          WideToUtf8(fixed_runtime_dir_.c_str()));
    }
  } else {
    use_fixed_runtime_ = false;
    if (reject_reason.empty()) {
      EmitLog("warn",
              "未检测到随包 WebView2 固定版（<exeDir>\\webview2），走系统 Evergreen");
    } else {
      EmitLog("error", "WebView2 固定版完整性校验未通过（" + reject_reason +
                           "），回退系统 Evergreen");
    }
  }
  if (!use_fixed_runtime_) {
    // 系统 Evergreen 运行时检查（登录网关同款依赖，缺失则如实上报）。
    LPWSTR version = nullptr;
    const HRESULT vr = ::GetAvailableCoreWebView2BrowserVersionString(
        nullptr, &version);
    if (FAILED(vr) || version == nullptr) {
      EmitLog("error", "WebView2 运行时不可用（hr=" + HexHResult(vr) +
                           "），请确认已内置固定版或系统已装 Edge WebView2");
      FailAll("WebView2 运行时不可用（hr=" + HexHResult(vr) + "）");
      return;
    }
    ::CoTaskMemFree(version);
    EmitLog("info", "系统 Evergreen WebView2 运行时已检测到");
  }
  BeginCreateEnvironment(use_fixed_runtime_);
}

void BaiduTokenBridge::OnEnvironmentCreated(HRESULT result,
                                            ICoreWebView2Environment* created) {
  if (phase_ != Phase::kCreatingEnv) return;
  if (FAILED(result) || created == nullptr) {
    // 创建失败统一处理：固定版 → Evergreen 回退重试一次；Evergreen →
    // 如实终止（HandleEnvCreateFailure 内区分）。
    HandleEnvCreateFailure(result, "回调");
    return;
  }
  env_ = created;
  EmitLog("info", "WebView2 环境创建成功");
  EnsureController();
}

void BaiduTokenBridge::EnsureController() {
  if (controller_ != nullptr) {
    SeedCookies();
    NavigateMain();
    return;
  }
  EnterPhase(Phase::kCreatingCtl, "创建WebView2控制器", 20000);
  auto handler = Microsoft::WRL::Callback<
      ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
      [this](HRESULT result, ICoreWebView2Controller* created) -> HRESULT {
        OnControllerCreated(result, created);
        return S_OK;
      });
  const HRESULT hr = env_->CreateCoreWebView2Controller(host_window_,
                                                        handler.Get());
  if (FAILED(hr)) {
    FailAll("创建 WebView2 控制器失败（hr=" + HexHResult(hr) + "）");
  }
}

void BaiduTokenBridge::OnControllerCreated(
    HRESULT result, ICoreWebView2Controller* created) {
  if (phase_ != Phase::kCreatingCtl) return;
  if (FAILED(result) || created == nullptr) {
    FailAll("创建 WebView2 控制器失败（回调 hr=" + HexHResult(result) + "）");
    return;
  }
  controller_ = created;
  // IsVisible 必须为 TRUE（窗口本身为主窗口内 2x2 鼠标穿透窗，用户无感）：
  // WebView2 对 IsVisible=FALSE 的 Widget 会挂起渲染/推迟 load 完成，
  // NavigationCompleted 不触发 → 任何网络环境下 25s 看门狗必超时（3.1854
  // 根因）。边界与宿主窗口同尺寸（2x2），降低无谓的渲染开销。
  controller_->put_IsVisible(TRUE);
  RECT bounds{0, 0, 2, 2};
  controller_->put_Bounds(bounds);
  if (FAILED(controller_->get_CoreWebView2(&webview_)) ||
      webview_ == nullptr) {
    FailAll("WebView2 内核对象获取失败");
    return;
  }
  // 导航完成事件：按次在 NavigateMain 内注册（携带代际，见该方法注释），
  // 此处不注册。
  // 渲染/浏览器进程异常：作废会话（下次调用重建），如实终止本次链路。
  // 关键修复：原实现只 FailAll 不释放对象，渲染进程死亡后 controller_/
  // webview_ 仍非空，下次调用 EnsureController 直接复用僵尸 COM 对象，
  // SeedCookies/Navigate 打在死对象上 → 原生崩溃（点重试闪退的根因）。
  // 3.1856 加固：InvalidateSession/Reply 一律 PostMessage 延迟到消息循环
  // 执行——在 WebView2 事件回调内直接 Close/Release COM 对象或触发
  // MethodChannel 回复，可能破坏 WebView2 回调链（文档建议 handler 内
  // 不做销毁）。
  auto proc = Microsoft::WRL::Callback<ICoreWebView2ProcessFailedEventHandler>(
      [this](ICoreWebView2* sender,
             ICoreWebView2ProcessFailedEventArgs* args) -> HRESULT {
        COREWEBVIEW2_PROCESS_FAILED_KIND kind =
            COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED;
        if (args != nullptr) {
          args->get_ProcessFailedKind(&kind);
        }
        // host_window_ 由 EnsureHostWindow 先行创建，此处理论非空；仍判空
        // 防御（PostMessage(NULL) 会向所有顶层窗口广播）。
        if (host_window_ != nullptr) {
          ::PostMessageW(host_window_, kProcessFailedMsg,
                         static_cast<WPARAM>(kind), 0);
        }
        return S_OK;
      });
  webview_->add_ProcessFailed(proc.Get(), &proc_token_);
  // 屏蔽新窗口（disk/main 可能弹窗）。
  auto win = Microsoft::WRL::Callback<
      ICoreWebView2NewWindowRequestedEventHandler>(
      [](ICoreWebView2* sender,
         ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
        if (args != nullptr) args->put_Handled(TRUE);
        return S_OK;
      });
  webview_->add_NewWindowRequested(win.Get(), &win_token_);

  EmitLog("info", "WebView2 控制器与内核对象创建成功，开始种 Cookie 并导航");
  SeedCookies();
  NavigateMain();
}

void BaiduTokenBridge::SeedCookies() {
  if (webview_ == nullptr || cookie_header_.empty()) return;
  Microsoft::WRL::ComPtr<ICoreWebView2_2> web2;
  if (FAILED(webview_.As(&web2)) || web2 == nullptr) {
    EmitLog("warn", "种 Cookie：未取得 ICoreWebView2_2（接口版本过低）");
    return;
  }
  Microsoft::WRL::ComPtr<ICoreWebView2CookieManager> manager;
  if (FAILED(web2->get_CookieManager(&manager)) || manager == nullptr) {
    EmitLog("warn", "种 Cookie：CookieManager 获取失败");
    return;
  }
  const auto pairs = ParseCookieHeader(cookie_header_);
  EmitLog("info", "种入 Cookie " + std::to_string(pairs.size()) + " 条到 .baidu.com");
  for (const auto& pair : pairs) {
    Microsoft::WRL::ComPtr<ICoreWebView2Cookie> cookie;
    if (FAILED(manager->CreateCookie(
            Utf8ToWide(pair.first).c_str(), Utf8ToWide(pair.second).c_str(),
            L".baidu.com", L"/", &cookie)) ||
        cookie == nullptr) {
      continue;
    }
    cookie->put_IsSecure(FALSE);
    cookie->put_IsHttpOnly(FALSE);
    manager->AddOrUpdateCookie(cookie.Get());
  }
}

void BaiduTokenBridge::NavigateMain() {
  if (webview_ == nullptr) {
    FailAll("WebView2 内核不可用");
    return;
  }
  // 代际递增 + 按次重注册导航回调（WebView2 事件本身不带代际信息）：
  // 旧链路遗留的导航（如看门狗超时未停的挂起导航被新 Navigate 取消）
  // 会补发 NavigationCompleted(FALSE)，若不校验代际，会误杀新链路为
  // 「disk/main 导航失败（网络/风控页）」——修复「超时后点重试秒败」。
  ++nav_generation_;
  if (nav_registered_ && webview_ != nullptr) {
    webview_->remove_NavigationCompleted(nav_token_);
    nav_registered_ = false;
  }
  auto nav = Microsoft::WRL::Callback<
      ICoreWebView2NavigationCompletedEventHandler>(
      [this, gen = nav_generation_](
          ICoreWebView2* sender,
          ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
        BOOL ok = FALSE;
        if (args != nullptr) args->get_IsSuccess(&ok);
        OnNavigationCompleted(gen, ok == TRUE);
        return S_OK;
      });
  webview_->add_NavigationCompleted(nav.Get(), &nav_token_);
  nav_registered_ = true;
  EnterPhase(Phase::kNavigating, "导航disk/main", 25000);
  EmitLog("info", std::string("导航 disk/main（代际 ") +
                      std::to_string(nav_generation_) + "，常态）");
  const HRESULT hr = webview_->Navigate(L"https://pan.baidu.com/disk/main");
  if (FAILED(hr)) {
    EmitLog("error", "disk/main 导航启动失败（hr=" + HexHResult(hr) + "）");
    FailAll("disk/main 导航启动失败（hr=" + HexHResult(hr) + "）");
  }
}

void BaiduTokenBridge::OnNavigationCompleted(int generation,
                                             bool succeeded) {
  if (phase_ != Phase::kNavigating) return;
  // 旧链路遗留的导航事件（含挂起导航被取消后补发的失败事件）→ 忽略。
  if (generation != nav_generation_) return;
  if (!succeeded) {
    EmitLog("error", "disk/main 导航失败（网络/风控页）");
    FailAll("disk/main 导航失败（网络/风控页）");
    return;
  }
  EmitLog("info", "disk/main 导航完成，等待 Set-Cookie 沉降 800ms");
  // 沉降 800ms：等服务端 Set-Cookie（指纹字段）落 Jar 后再取号。
  EnterPhase(Phase::kSettle, "Set-Cookie沉降", 0);
  ::SetTimer(host_window_, kSettleTimer, 800, nullptr);
}

void BaiduTokenBridge::OnSettle() {
  ::KillTimer(host_window_, kSettleTimer);
  if (phase_ != Phase::kSettle) return;
  EmitLog("info", "Set-Cookie 沉降完成，开始执行页面取号脚本");
  EnterPhase(Phase::kExecuting, "页面fetch", 15000);
  RunScript();
}

// ─────────────── 页面取号 ───────────────

void BaiduTokenBridge::RunScript() {
  if (webview_ == nullptr) {
    FailAll("WebView2 内核不可用");
    return;
  }
  // 脚本代际：旧链路迟到的 ExecuteScript 结果（如看门狗杀链后另起新链）
  // 因代际不符被忽略，防止跨链路串扰（把上一轮结果答复给当前等待者）。
  const int gen = ++script_generation_;
  EmitLog("info", "执行页面取号脚本（代际 " + std::to_string(gen) + "）");
  // 注意：接口 Invoke 第二参数为 LPCWSTR（只读），WRL::Callback 会按接口签名
  // 校验 lambda 参数类型，写 LPWSTR 将报 C2664。
  auto handler = Microsoft::WRL::Callback<
      ICoreWebView2ExecuteScriptCompletedHandler>(
      [this, gen](HRESULT result, LPCWSTR json) -> HRESULT {
        if (gen != script_generation_) {
          return S_OK;  // 旧链路结果，忽略。
        }
        if (FAILED(result) || json == nullptr) {
          FailAll("页面脚本执行失败（hr=" + HexHResult(result) + "）");
          return S_OK;
        }
        OnScriptResult(WideToUtf8(json));
        return S_OK;
      });
  const HRESULT hr =
      webview_->ExecuteScript(Utf8ToWide(kBdstokenJs).c_str(), handler.Get());
  if (FAILED(hr)) {
    FailAll("页面脚本提交失败（hr=" + HexHResult(hr) + "）");
  }
}

void BaiduTokenBridge::OnScriptResult(const std::string& js_return_json) {
  if (phase_ != Phase::kExecuting) {
    return;  // 非本链路执行态的迟到结果，忽略。
  }
  const std::string inner = DecodeJsonStringLiteral(js_return_json);
  const bool http_ok = inner.find("\"httpOk\":true") != std::string::npos;
  const int errno_code =
      FindJsonIntValue(inner, "errno", http_ok ? -2 : -1);
  std::string token = FindJsonStringValue(inner, "bdstoken");
  if (token.empty()) {
    token = FindJsonStringValue(inner, "pageToken");
  }
  const std::string js_err = FindJsonStringValue(inner, "err");

  if (errno_code == 0 && !token.empty()) {
    last_fetch_ok_ = true;
    EmitLog("info", "取号成功：bdstoken 长度=" + std::to_string(token.size()));
    FetchJarCookiesThenComplete(token);
    return;
  }

  // 失败 → 种 Cookie + 重导航补一次（覆盖「凭据 Cookie 未生效 / 被清」场景）。
  if (!seed_retry_done_ && errno_code != -100) {
    seed_retry_done_ = true;
    SeedCookies();
    NavigateMain();
    return;
  }

  last_fetch_ok_ = false;
  // 3.1862 诊断增强：失败时带出 HTTP 状态码与响应体摘要——区分「百度有
  // 响应（风控页/风控 JSON）」vs「网络层失败（fetch 抛异常，status=0）」，
  // 消灭「疑似风控页」这类无证据猜测。
  const int http_status = FindJsonIntValue(inner, "status", 0);
  const std::string body_excerpt =
      Excerpt(FindJsonStringValue(inner, "body"), 200);
  std::string message;
  if (errno_code == -6) {
    message = "百度登录态被风控（errno=-6，HTTP " + std::to_string(http_status) +
              "，body=" + body_excerpt + "）——请到授权中心重新扫码登录";
  } else if (!js_err.empty()) {
    message = "页面取号异常：" + js_err;
  } else if (!http_ok) {
    message = "gettemplatevariable 请求未成功（HTTP " +
              std::to_string(http_status) + "，body=" + body_excerpt + "）";
  } else {
    message = "响应未含 bdstoken：" + Excerpt(inner, 160);
  }
  EmitLog("error", "取号失败（errno=" + std::to_string(errno_code) + "）：" + message);
  CompleteAll(errno_code, std::string(), std::string(), message);
}

void BaiduTokenBridge::FetchJarCookiesThenComplete(const std::string& token) {
  Microsoft::WRL::ComPtr<ICoreWebView2_2> web2;
  Microsoft::WRL::ComPtr<ICoreWebView2CookieManager> manager;
  if (webview_ == nullptr || FAILED(webview_.As(&web2)) || web2 == nullptr ||
      FAILED(web2->get_CookieManager(&manager)) || manager == nullptr) {
    CompleteAll(0, token, std::string(), "Jar Cookie 读取失败（token 已取得）");
    return;
  }
  auto handler = Microsoft::WRL::Callback<
      ICoreWebView2GetCookiesCompletedHandler>(
      [this, token](HRESULT result, ICoreWebView2CookieList* list) -> HRESULT {
        std::string joined;
        if (SUCCEEDED(result) && list != nullptr) {
          UINT32 count = 0;
          list->get_Count(&count);
          for (UINT32 i = 0; i < count; ++i) {
            Microsoft::WRL::ComPtr<ICoreWebView2Cookie> cookie;
            if (FAILED(list->GetValueAtIndex(i, &cookie)) || cookie == nullptr) {
              continue;
            }
            LPWSTR name = nullptr;
            LPWSTR value = nullptr;
            if (FAILED(cookie->get_Name(&name)) || name == nullptr) continue;
            cookie->get_Value(&value);
            if (!joined.empty()) joined += "; ";
            joined += WideToUtf8(name) + "=" +
                      (value != nullptr ? WideToUtf8(value) : std::string());
            ::CoTaskMemFree(name);
            if (value != nullptr) ::CoTaskMemFree(value);
          }
        }
        EmitLog("info", "取号链路完成：回传 bdstoken 与 Jar Cookie");
        CompleteAll(0, token, joined, std::string());
        return S_OK;
      });
  const HRESULT hr = manager->GetCookies(L".baidu.com", handler.Get());
  if (FAILED(hr)) {
    CompleteAll(0, token, std::string(), "Jar Cookie 读取失败（token 已取得）");
  }
}

}  // namespace vbox
