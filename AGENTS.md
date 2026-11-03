# AGENTS.md

## 工程功能简述

VBox：多端聚合影视/网盘播放客户端。iOS 实现（Swift/SwiftUI）为唯一真相源，
Flutter 侧对齐实现 Android / macOS / Windows 三端。核心能力：站源爬虫
（Python/QuickJS/JSC 运行时）、网盘直链播放（百度/夸克/迅雷/UC/139 等，
含本机 Node 常驻链）、libmpv / ExoPlayer / AVPlayer 多内核播放、下载、
投屏、福利区等。

## 关键目录结构

```
lib/
  core/           基础设施（日志、网络、存储、常量、工具）
  data/           数据源（remote/local）、模型、仓库
  domain/         领域实体（cloud/player/spider/live/welfare/music…）与用例
  platform/       平台能力桥（player、download、spider、webview、node、runtime…）
  presentation/   UI（pages、shell、theme、widgets、ui_mode）
  main.dart       入口
windows/runner/   Windows 原生（播放器插件 player_plugin.cpp/.h、libmpv）
macos/Runner/     macOS 原生（PlayerPlugin.swift 等）
android/app/      Android 原生（JNI、node_bridge、Python 桥）
vbox/             iOS 参考实现（Swift，唯一真相源）
assets/           字体、品牌图、noderuntime、python-stdlib
scripts/          构建/打包/契约校验脚本
contract/         跨端契约（schema、abi、docs）
docs/             方案与对齐文档
```

## 约定

- 回复与代码注释使用中文。
- Flutter 侧改动须与 iOS 参考实现对齐；差异需在注释中写明对齐点。
- 日志统一走 `lib/core/utils/logger.dart` 的 `AppLog`（分类如
  `LogCategory.player` / `cloud` / `network`），不散落 `print`。
- 原生播放器日志经 EventChannel `com.vbox.player/player/events` 的
  `log` 事件上抛，由 `ChannelPlayer` 转入 `AppLog`（category=player）。

## 近期改动同步

- `lib/presentation/pages/cloud/native_cloud_drive_login_gateway.dart`：
  百度扫码 Cookie 补全对齐 iOS（5 端点 + `gettemplatevariable` 参与
  Set-Cookie 收集 + errno 日志）。
- `lib/data/datasources/remote/baidu_ibox_client.dart`：`fetchUserBdstoken`
  四层兜底补 errno 检查与分级日志，来源名对齐 iOS；`_webViewBdstoken`
  同时返回 WebView CookieJar 的 cookie，并对「WebView2 未就绪 / 载入失败」
  留痕；第 1 层响应非 JSON 时记录 status/content-type/长度（旧代码静默跳过
  是「取不到 bdstoken」的疑因）。
- `lib/platform/player/pan_player.dart`：`_saveBaiduBdstoken` 对齐 iOS
  `baiduPersistUserBdstoken`（合并 cookie + 更新登录态），并在 bdstoken /
  source / cookie 均无变化时跳过写盘。
- `lib/platform/player/channel_player.dart`：新增 `log` 事件处理，原生
  播放日志转 `AppLog`。
- `windows/runner/player_plugin.cpp/.h`：
  - **双渲染后端**：优先 OpenGL（离屏 FBO + `glReadPixels`），失败自动回退
    `MPV_RENDER_API_TYPE_SW` 软件渲染（`SW_SIZE/SW_FORMAT("bgra")/SW_STRIDE/SW_POINTER`），
    保证 GL 不可用（无显卡驱动 / 远程桌面 / 仅 GL 1.1）时仍有画面。
  - GL 能力预检 `ProbeGlCapability` **仅写日志、不作 `vo` 闸门**（避免预检误判
    导致本来能出画面却不出）。
  - 渲染链各失败路径日志、mpv 内部日志上抛、渲染失败非致命提示、引擎未释放
    前缓冲导致的丢帧留痕。
  - `RenderFrame` 拆出 `ResolveVideoSize` / `PublishFrame`，两后端共用上屏尾段。
- `macos/Runner/PlayerPlugin.swift`（对齐 Windows 同口径）：
  - **双渲染后端**：OpenGL（NSOpenGL 3.2 core + 离屏 FBO）失败自动回退
    `"sw"` 软件渲染。
  - 渲染链各失败路径日志（GL 入口缺失清单 / 像素格式 / render_context /
    FBO / 首帧）、mpv 内部日志上抛（`mpv_request_log_messages` +
    `log` 事件）、渲染失败非致命提示。
  - `renderMpvFrame` 拆出 `publishMpvFrame`，两后端共用上屏尾段。
- `android/app/src/main/kotlin/com/vbox/player/PlayerPlugin.kt`：
  新增 `log` 事件上报（open / 后端就绪 / 视频轨尺寸 / 播放错误 / 后端初始化
  失败），与 Windows/macOS 日志详细度对齐（Android 不走 mpv，无渲染后端问题）。
- `windows/runner/player_plugin.cpp`：mpv 初始化启用高质量渲染档位
  （`profile=high-quality`，旧版回退 `gpu-hq`），并显式钉住
  `correct-downscaling=yes` / `linear-downscaling=no` / `sigmoid-upscaling=yes`。
  修复「所有资源画质发虚、iOS 无此现象」：mpv 默认 scale/cscale=bilinear 且
  未开 correct-downscaling，窗口化缩放的画质明显劣于 iOS AVPlayer。
  macOS PlayerPlugin.swift 走同一 mpv 管线，后续可同步同参。
- `lib/presentation/pages/player/player_page.dart` /
  `lib/presentation/pages/search/search_page.dart`：调试日志导出在 Windows
  不走 SharePlus 系统共享面板（未打包应用必然弹「我们无法为你显示所有共享
  方法」），改为写入「下载」目录并在资源管理器中定位；失败退化为剪贴板。
- `windows/runner/baidu_token_bridge.{h,cpp}` + `windows/runner/webview2/`
  （WebView2 SDK 1.0.2903.40 头文件与静态加载器）+
  `windows/runner/player_plugin.{h,cpp}`（`com.vbox.player/cloud_bridge`
  通道）+ `lib/platform/webview/baidu_native_token_bridge.dart` +
  `lib/data/datasources/remote/baidu_ibox_client.dart`：
  普通百度网盘 bdstoken **原生 WebView2 桥**。凭据 Cookie 种入 WebView2
  持久化 Jar（`%APPDATA%\com.vbox\vbox\win_baidu_webview`）→ 真实浏览器栈
  导航 disk/main → 页面上下文 fetch gettemplatevariable（复刻 iOS
  WKWebView 系统网络栈信任度）→ Jar 全量 Cookie 回传合并回写凭据。
  owned 弹出窗口承载 Controller（3.1856 起为主窗口内 2x2 鼠标穿透形态，
  见下方 3.1854/3.1856 条目；不经 Flutter 插件 WebView，规避 3.1839 闪退 /
  3.1844 白屏路径）；全阶段看门狗，errno!=0 时种 Cookie 重导航一次后如实回传
  交 Dart 兜底链。
- `windows/runner/baidu_token_bridge.{h,cpp}`（3.1854 取号超时根因修复 +
  3.1856 修正）：
  - 宿主窗口「主窗口内 2x2 鼠标穿透」（3.1856，对齐 iOS「1x1 WKWebView
    addSubview 到可见 key window」）：主窗口客户区右下角内侧 2x2 owned 弹窗
    （`WS_EX_TRANSPARENT|WS_EX_NOACTIVATE|TOOLWINDOW`），`SW_SHOWNOACTIVATE`
    显示，Controller `IsVisible=TRUE`。3.1854 曾停靠「虚拟屏外」，但 Chromium
    `NativeWindowOcclusionTracker` 会把完全不在任何显示器区域内的窗口判定
    hidden/occluded → 3.1855 云电脑实测 NavigationCompleted 仍不触发（25s
    超时照旧）。挂在主窗口内则几何在屏幕内且 owned 弹窗恒在 owner 之上 →
    occlusion 判定可见。每条链路开始刷新停靠位（跟随主窗口移动/缩放）。
  - `ProcessFailed` 作废会话（`InvalidateSession`，浏览器主进程亡连环境一并
    重建）：修复渲染进程死亡后复用僵尸 COM 对象导致的「点重试闪退」；
    3.1856 起回调内只 `PostMessage(kProcessFailedMsg)`，销毁/回复延迟到
    消息循环执行（不在 WebView2 回调链内 Close/Release COM）。
  - 导航/脚本回调带代际校验：看门狗超时未停的挂起导航在新链路 Navigate 时
    补发的取消事件不再误杀新链路；迟到的 ExecuteScript 结果不再跨链路串扰。
  - 3.1882 起移除 `interactive` 交互验证模式（含 `ShowVerifyWindow` /
    `HideVerifyWindow` / `OnVerifyWindowClosed` 与 `interactive_` 成员），
    按用户要求整体下线、不再人工兜底。
- `lib/data/datasources/remote/baidu_ibox_client.dart` /
  `lib/platform/webview/baidu_native_token_bridge.dart`（3.1882）：
  移除 `_nextFetchInteractive` 重试置位，取号失败提示改为「建议重新扫码登录
  或粘贴完整 Cookie」；`fetchBdstoken` 移除 `interactive` 形参；
  `fetchBdstokenWinHttp` 返回值扩展携带富集后 `cookie`。
- `lib/presentation/pages/cloud/native_cloud_drive_login_gateway.dart`：
  重新扫码落库合并既有 `extra`（此前整体覆盖会把播放链回写的 `bdstoken`
  抹掉，形成「重登→兜底值丢失→再失败」死循环）。
- `windows/runner/player_plugin.{h,cpp}` + `lib/presentation/widgets/player/
  video_surface.dart`（3.1854 画质修复 + 3.1856 闪退/偏色修正）：
  - **按显示尺寸渲染**：`CopyPixelBuffer` 的引擎入参（纹理显示物理像素）
    原被忽略，现记录并在渲染线程取 `min(视频, 显示)` 为渲染目标——缩小由
    mpv 高质量缩放器（ewa_lanczossharp）完成，修复「4K 按原尺寸渲染、缩小
    全靠 Flutter bilinear」的发虚/摩尔纹（此前 mpv profile 修复无效的根因：
    FBO=视频原尺寸，mpv 内部缩放根本没参与）；回读带宽同步下降。纵横比上
    报始终用视频原始尺寸（与渲染目标解耦）。
  - **filterQuality 回退 low（3.1856 闪退修复）**：3.1854 曾改 medium，
    Windows 桌面引擎的外部纹理（PixelBufferTexture）无 mipmap 链，medium
    采样触发引擎 mipmap 路径后于 flutter_windows.dll 内 fastfail 闪退
    （3.1855 云电脑三连崩，WER BEX64 c0000409；iOS Metal 外部纹理路径无
    此问题）。按显示尺寸渲染后纹理 1:1 上屏，low 足够。
  - SW 软渲染色彩钉扎：`target-prim=bt.709` / `target-trc=srgb` /
    `tone-mapping=bt.2390`（软转换缺省仅 YUV→RGB 矩阵导致泛黄偏色）；
    3.1856 起 GL 路径同口径钉扎（消除 FBO 输出目标色彩空间歧义）。
  - **GL 回读颜色自检（3.1856 偏色根因修复）**：预检向 FBO 画已知纯色
    （红+绿双色）并回读比对 BGRA 字节序——虚拟化 GPU（真名不在黑名单的
    GRID/Paravirtual 等）`glReadPixels` 可能输出通道交换/错乱颜色，
    glFinish 修撕裂修不了颜色；黑名单只能枚举已知型号，实测回读字节才是
    确定性判据，不符即强制 SW（SW 色彩已钉扎）。
    `VBOX_FORCE_SW_RENDER=1` 环境变量强制 SW（逃生门）。
  - `FILE_LOADED` 上报视频色彩参数（pixfmt/primaries/gamma/hwdec），偏色
    类问题日志一眼定位 HDR/601/709 与解码路径。
- `windows/runner/baidu_token_bridge.cpp` + `scripts/bundle-webview2-windows.ps1`
  + `.github/workflows/build-release-assets.yml`（3.1857 百度取号「WebView2
  运行时不可用」根治 · 对齐 iOS「系统浏览器永远可用」）：
  - 3.1857 前原生桥依赖系统 Edge WebView2 Evergreen 运行时
    （`CreateCoreWebView2EnvironmentWithOptions(nullptr, ...)`）；精简系统/
    云电脑镜像未装时 `GetAvailableCoreWebView2BrowserVersionString` 返回
    `ERROR_FILE_NOT_FOUND`（0x80070002），取号在环境检测第一步即失败——与
    3.1854/3.1856 修复的「窗口可见性 / 导航超时」是两条无关的失败路径。
  - 修复为「随包内置固定版（Fixed Version）」：新增
    `WebView2BrowserExecutableDir()` 定位 `<exeDir>\webview2`，存在则离线加载
    （`CreateCoreWebView2EnvironmentWithOptions(fixed_dir, ...)`），否则回退
    系统 Evergreen 检测——未打包内置时行为与旧版一致，可安全回退。
  - `bundle-webview2-windows.ps1` 把 CI 构建机（windows-latest 预装 Edge
    WebView2）已就位的运行时复制为固定版到 `Release\webview2\`（排除
    Installer/SetupMetrics 缓存），installer.iss 递归打包自动携带。
  - **HRESULT 打印 bug 修复**：旧代码 `"0x" + std::to_string(十进制)` 把
    0x80070002 误打印成 `0x2147942402`（十进制 2147942402 = unsigned
    0x80070002），排查方向完全跑偏；新增 `HexHResult()` 统一按大写十六进制
    打印，8 处失败文案全部改用。
  - **原生日志回调上抛**：`BaiduTokenBridge` 新增 `SetLogCallback` + `EmitLog`
    （level ∈ debug/info/warn/error），PlayerPlugin 构桥后挂接 → `[baidu]`
    前缀经 `player/events` log 事件上抛 Dart AppLog。取号链路每一阶段
    （固定版检测/COM/环境/控制器/种 Cookie/导航/脚本/成功回传）都有留痕，
    满足「有错误就打印错误日志」的排查诉求。

## 日志事件契约（跨端）

`EventChannel com.vbox.player/player/events` 支持 `log` 类型：

```
{ "type": "log", "level": "info|warn|error|debug", "message": "…" }
```

Dart `ChannelPlayer._onEvent` 收到后转 `AppLog`（category=player，tag
`player-native`）。三端均已实现（Windows C++ / macOS Swift / Android Kotlin）。

## 已知待决问题

- 百度 `pcs_cookie` 在 iOS 与 Flutter 均无写入点，`pcs` 两端恒空，非差异。
- 渲染线程启用 `MPV_RENDER_PARAM_ADVANCED_CONTROL` 的帧回报契约已补齐：`MpvApi`
  现解析 `mpv_render_context_report_swap()`，OpenGL 与软件渲染路径均在
  `mpv_render_context_render()` 成功后回报一帧 swap，维持 mpv 帧节流/播速/timing
  正确（对齐 `windows/runner/player_plugin.{h,cpp}`）。

## 3.1858 视频纹理三缓冲 + WinHTTP 取号前置层

- `windows/runner/player_plugin.{h,cpp}`：
  - **闪退根因（0xC0000409 实锤）**：Flutter 引擎要求 `CopyPixelBuffer`
    返回的 buffer 尺寸 == 引擎传入的显示尺寸；3.1857 的「min(视频,显示)」
    渲染在小分辨率视频 + 大窗口时返回小 buffer → 引擎 fastfail（事件日志
    `flutter_windows.dll` c0000409）。修复：渲染目标**严格 = 引擎显示尺寸**
    （缩放全部交给 mpv 高质量缩放器，同时消除引擎 bilinear 二次放大的发虚），
    `CopyPixelBuffer` 加尺寸一致性防御（不一致返回 nullptr，引擎沿用旧帧）。
  - **卡顿根因 + 三缓冲帧池**：旧单缓冲在引擎持帧未 release 期间只能丢帧，
    vsync 采样与 mpv 出帧节奏不齐时周期性丢帧 = 「一卡一卡」。改为 3 槽
    `FrameSlot` 环池（buffer/width/height/locked/seq）：渲染线程写最旧空闲槽、
    引擎取最新空闲槽、`FrameReleaseContext` 定位归还槽；Shutdown 等全部槽
    归还后清空。读写不再互斥，丢帧理论上不再出现。
- `windows/runner/baidu_token_bridge.{h,cpp}` + `player_plugin.cpp`
  （`cloud_bridge` 通道）+ `lib/platform/webview/baidu_native_token_bridge.dart`
  + `lib/data/datasources/remote/baidu_ibox_client.dart`：
  - **WinHTTP（Schannel 系统栈）bdstoken 直取**：`FetchBdstokenViaWinHttp`
    同步 GET `gettemplatevariable`（Cookie/Referer/UA 对齐 Dart 第 1 层，
    紧超时 5s/8s），通道方法 `getBdstokenWinHttp`。Dart 侧
    `fetchUserBdstoken` 在 WebView2 之前插入「第 0 前置层」——对齐 iOS
    第 1 层 URLSession 的系统栈语义，不依赖 WebView2 运行时/窗口；errno
    留痕判定百度对 Schannel 指纹的信任度（0=通过，-6=仍需 WebView2 兜底）。
  - CMakeLists 链接 `winhttp.lib`。
- `.github/workflows/build-release-assets.yml`：**移除 WebView2 固定版随包
  分发**（523MB → ~246MB），取号回退系统 Evergreen 检测 + WinHTTP 前置层，
  未装 WebView2 的机器由 WinHTTP 层承接。

## 3.1858 补充：硬解 + 偏色像素转储排查工具（用户日志实锤驱动）

- `windows/runner/player_plugin.cpp`：
  - **hwdec=auto-copy**（卡顿第二根因）：用户日志实测 4K HEVC 60fps 10-bit
    在 SW 软渲染下 `hwdec=no` 纯 CPU 软解，伴随连续 `Audio device underrun`
    （CPU 彻底过载）——「一卡一卡」的另一半根因（另一半是单缓冲丢帧，已由
    三槽环池修复）。取 `auto-copy`（D3D11VA 解码后拷回内存，GL/SW 双路径
    通吃，零拷贝 interop 在离屏 WGL 上下文有兼容风险故不走）；RDP 会话仅
    WARP 时 mpv 自动回退软解，无副作用。
  - **SW 路径色彩钉扎无效的实锤与对策**：用户 3.1857 实测仍偏色，证明
    `target-prim/target-trc/tone-mapping` 在 render API SW 模式（libswscale
    软转换）下不生效（仅作用于 GPU 渲染管线）。新增 **VBOX_DUMP_FRAME=1
    首帧像素转储**（`DumpFirstFrameToBmp`，GL/SW 汇聚点 `PublishFrame` 落
    盘 24 位 BMP 到 %TEMP%）：像素级区分偏色责任方——BMP 正常而屏幕偏色 →
    显示器/系统色彩配置；BMP 偏色 → mpv 渲染管线。
  - **target-trc 钉扎修正（srgb → bt.1886，双机器同偏色的主嫌疑）**：家用
    电脑与云电脑同样「偏冷发蓝 + 灰蒙蒙低对比」= 渲染管线系统性问题。
    3.1856 曾把 TRC 钉 `srgb`——bt.1886(≈2.4)→sRGB(≈2.2) 会整体提亮中间
    调，恰是「灰蒙蒙」经典症状；iOS mpv 直通 Metal 默认 bt.1886 原样输出。
    GL/SW 两路径统一改钉 `bt.1886`（对齐 iOS 基准），prim 保持 bt.709、
    tone-mapping=bt.2390 保留（仅 HDR→SDR 生效）。
- `lib/presentation/pages/player/player_page.dart`：**调试浮层汇入原生层日志**。
  旧浮层只显示 Dart 层生命周期日志（起播/切集/错误），`player-native` tag 的
  原生日志（mpv 初始化/首帧上屏/渲染后端/FBO 自检/色彩参数/[baidu] 取号桥）
  只进 AppLog 落盘文件，浮层与导出文件都看不到关键排障行。现订阅
  `AppLog.stream` 过滤 `player-native` tag，以 `[原生]` 前缀汇入
  `_playerLogs`——浮层、错误态日志视图、导出文件三处内容一致，偏色/闪退/
  取号问题一处看全（三端通用：Windows/macOS/Android 原生日志同 tag）。

## 3.1859 云电脑实测三问题修复：切集闪退 UAF / 首帧黑帧闸门 / 固定版完整性校验

用户云电脑实测三问题：① 切集偶发闪退（WER 0xC0000409，
flutter_windows.dll+0xfb4909 两次同偏移）；② 播放黑屏有声无画；③ 百度取号
挂起 25s 超时（固定版目录 142/155 文件混杂实锤）。

- `windows/runner/player_plugin.cpp`：
  - **切集闪退（UAF 实锤）**：`ShutdownMpv` 1s 有界等待超时后仍强制复位
    全部帧槽（含引擎仍持有的 locked 槽 buffer）→ 引擎纹理拷贝路径访问已
    释放内存（确定性崩溃偏移与纹理拷贝吻合）。修复：只复位未锁定槽，
    locked 槽原样保留（含 buffer），等 `OnPixelBufferReleased` 归还时复位；
    该回调同步复位 seq/width/height 防「旧帧被新会话误取」，buffer 内存
    保留不 clear（此刻刚解锁，与渲染线程 swap 该槽存在竞争，内存由
    PublishFrame 重装新帧时自然回收）。
  - **黑屏（mpv 空渲黑帧实锤）**：4K 日志「首帧已渲染上屏」出现在
    FILE_LOADED+3ms，而 VO reconfig（3840x2160）在 +1.6s——首帧是 mpv
    空渲黑帧；叠加 4K 纯 CPU 软解过载（Audio device underrun）长时间停留
    黑帧。修复（双闸门）：`RunRenderLoop` 仅在 render_context_update
    flags 含 kRenderUpdateFrame 时调 `RenderFrame`；`RenderFrame` 前置
    `video-params/pixelformat` 非空闸门（首个视频帧完成输出配置才渲染
    发布；纯音频源恒空同样被拦。SW_SIZE=17 等枚举已核对与 mpv v0.41 ABI
    一致，排除枚举错配嫌疑）。
  - **VBOX_HWDEC 逃生门**：硬解选择支持环境变量覆盖（no/auto-copy/auto），
    硬解异常机器可就地切软解复测，免重新构建（默认 auto-copy 不变）。
  - **首帧像素统计**：首帧发布时统计非黑像素占比（luma>=16）与平均亮度并
    EmitLog 一次——复测时区分「mpv 输出黑」vs「引擎合成丢帧」。
- `windows/runner/baidu_token_bridge.{h,cpp}`（取号 25s 超时根因修复）：
  - **固定版完整性三级校验**（`WebView2BrowserExecutableDir` 加
    reject_reason 出参）：级 1 加载器探测（
    GetAvailableCoreWebView2BrowserVersionString 能从固定版目录解析出
    非空版本）；级 2 exe VERSIONINFO FileVersion 与探测版本前三段比对；
    级 3 核心 dll（msedgewebview2.dll）版本与 exe 比对——直接抓「exe 与
    核心 dll 版本错配」的混杂目录（本机实测主症状：环境创建成功、导航
    无响应 25s 超时）。reject_reason 约定：返回空串时空 = 目录不存在
    （未检测到），非空 = 存在但校验拒绝（原因留痕日志）。
  - **固定版失败 → Evergreen 自动重试一次**：环境创建（同步/回调）失败
    且当前用固定版 → `evergreen_retry_used_` 标记后改用系统 Evergreen
    重试（对齐 iOS「系统浏览器永远可用」）；重试过或本就 Evergreen →
    如实 FailAll。环境创建段重构为 `BeginCreateEnvironment` /
    `HandleEnvCreateFailure`（StartChain 与重试共用）。
  - **看门狗超时兜底**：固定版链路走到看门狗超时（混杂目录「创建成功但
    导航无响应」，校验不一定拦得住）→ 标记回退，下次取号跳过固定版直接
    走系统 Evergreen。
  - 版本串解析用 `std::stoi`（ParseVersionPrefix3），版本读取复用
    version.lib（CMakeLists 已链接，无新依赖）。

## 3.1862 黑屏误诊回退 + 取号诊断增强

- **误诊记录（重要教训）**：曾判断「Windows 黑屏 = 页面只监听
  onSurfaceChanged 而原生只发 textureReady → _textureId 恒 null」，并在
  player_page.dart 补挂 `_player.onTextureReady`——实际 PlayerController
  早在 cef5f44096（10-14「修复百度网盘播放异常与 Windows 安装器进度卡死」）
  的 `_attach()` 里就把底层 textureReady 重映射到 onSurfaceChanged
  （player_controller.dart L326-328），挂载链在用户实测版本里本就畅通；
  且 PlayerController 并无 onTextureReady setter，该改动导致 flutter
  analyze 两处 error、flutter-analyze job 失败、build-windows 全线 skip
  （首例 CI 编译失败即 3.1862 首推 e7073f40）。本节已整体回退，
  player_page.dart 恢复 3.1861 原状。
- **黑屏真因重新定向**：原生发布链正常（mpv 首帧非黑像素 79%）、
  事件链（textureReady → channel 分发 → 重映射 → onSurfaceChanged →
  setState）代码级畅通、VideoSurface 有 textureId 即渲染 Texture——
  嫌疑转向引擎侧像素缓冲拉取路径（PixelBufferTexture.CopyPixelBuffer
  返回内容 / 槽位锁定归还时序 / 纹理注册尺寸），待复测日志定位。
- **基线说明**：player_page.dart 本次回退已逐字节比对远端
  c522f30f（3.1862 版本号提交）内容一致后才推送，无覆盖风险。

## 3.1862 取号失败诊断增强：扫码链全景日志 + 桥层失败详情带响应体

- **背景**：家用电脑/云电脑均出现「普通百度网盘加载失败」，用户未开代理、
  扫码登录早已成功，取号链四层兜底（WinHTTP → 原生 WebView2 桥 → Dart
  HttpClient → HTML 解析）仍全挂。代码注释自证「Windows 端 Dart 富集走
  HttpClient 指纹被风控、BAIDUID 补不全 → 落库凭据缺指纹」（L723-726），
  但缺运行时证据，先加日志不动逻辑，复测定位真凶后精准修。
- **扫码链诊断**（`native_cloud_drive_login_gateway.dart`）：
  - 扫码 Cookie 校验失败留痕：总长 + 键名列表（要求含 BDUSS+STOKEN）；
  - 扫码成功后凭据链全景日志（`baidu-auth` tag）：扫码 Cookie 键名 →
    原生 WebView2 富集结果 → Dart 富集 extra 键 → 最终落库 Cookie 键名
    与总长，只打键名不打值防凭据泄露（新增 `_cookieKeyNames` helper）。
  - 复测预期：若全景日志显示最终落库 Cookie 缺 BAIDUID/BDCLND 等指纹键，
    即坐实「落库凭据缺指纹」推理。
- **桥层诊断**（`baidu_token_bridge.cpp`）：
  - WinHTTP 非 200 / errno!=0 失败 detail 携带响应体前 160 字节摘要
    （errno=-6 风控码的 57 字节 body 内容直接可见）；
  - OnScriptResult 失败分支回传 HTTP status + body 前 200 字节
    （区分「网络层请求未成功」与「百度服务端 errno 风控」）。
  - 复测预期：日志直接暴露 gettemplatevariable 实际返回内容，判断
    是凭据指纹缺失还是 IP/UA 风控。

## 3.1863 黑屏回归点回退 + SW 软渲染偏色直接修对 + 色彩链路诊断日志

用户纠正：「不单单是人物偏色，整个视频画面颜色都不一样；iOS 早期也遇到过、
后来修好了」——根因是 iOS 走 GPU 渲染（`vo=gpu-next` + `gpu-api=vulkan` +
moltenvk + videotoolbox），完整 GPU 色彩管线，故色彩正确；Windows 端退 SW
软渲染（libswscale）无色彩管理才是偏色主因，而非 601/709 参数微调所能解决。
本版按用户要求「不降级兜底、有问题直接输出日志」落地。

- `windows/runner/player_plugin.cpp`（黑屏回退 · 确定性修复）：
  - **移除 FRAME 闸门**（`RunRenderLoop`）：3.1859 加的「仅 kRenderUpdateFrame
    时渲染」是黑屏回归点——首帧在 VO reconfig 时渲染消耗 FRAME 标志后，慢解码/
    软解过载下后续真实帧的 FRAME 通知不再可靠置位 → 持续黑屏。恢复旧版「每
    100ms 无条件渲染」拉取式，`render_context_update` 返回值不再作门槛；真实帧
    解出前由 `ResolveVideoSize`（尺寸未就绪即 return）兜住，不渲空帧。
  - **移除 pixelformat 闸门**（`RenderFrame`）：3.1859 加的
    `video-params/pixelformat` 空检查同为黑屏回归点，删除。
  - **SW 路径色彩改 colormatrix 系列**：旧 target-prim/target-trc/tone-mapping
    属 GPU 项、libswscale 软转换不识别（3.1858 已实锤不生效）。改设
    `colormatrix=bt.709` / `colormatrix-primaries=bt.709` /
    `colormatrix-gamma=bt.1886`，逐项记录 `set_option_string` 返回值（<0 =
    mpv-2.dll 未识别该选项，日志一眼可见是否被接受），而非盲改。
  - **首帧色彩参数日志增强**：`PublishFrame` 首帧渲染成功后补打真实
    `video-params/primaries` / `gamma` / `colormatrix` / `colorlevels`——
    FILE_LOADED 时机 video-params 尚空（实测日志为空），VO reconfig 后首帧才
    就绪，故移到首帧统一留痕；偏色（矩阵 601/709、range limited/full、
    primaries/gamma 缺失）一眼定位。偏色硬证据链保留：`VBOX_DUMP_FRAME` 默认
    开启首帧 BMP 转储（设 0/false/no/off 关闭；BMP 偏色→渲染管线，BMP 正常→
    显示器/系统）。

- **待办（发布前关闭）**：`VBOX_DUMP_FRAME` 已默认开启——起播首帧自动转储 BMP
  到 `%TEMP%` 用于偏色定责。偏色定位/修复后务必改回默认关闭（恢复需显式设置才
  转储），避免正式版每次起播都写临时文件。

## 3.1864 修复首帧诊断假黑（时序 bug）+ 前 10 帧逐帧统计

用户复测仍「只有声音没画面」。定位发现：首帧 BMP 全黑（R/G/B 均 0）是首帧
捕获时序 bug 造成的假象——`logged_first_frame_` 在第一个经过 `PublishFrame` 的
帧即置 true，但该帧是 VO reconfig 后、真实像素解出前的 pre-decode 空帧（SW
缓冲 0 初始化、mpv `render_context_render` 返回成功但未写入真实像素），导致
BMP 与色彩诊断全部浪费在黑帧上，后续真实帧不再转储/统计，误判为「渲染管线
坏了」。注：日志侧看到的仍是 3.1859 旧版日志（10/17），新诊断行尚未导出。

- `windows/runner/player_plugin.{h,cpp}`（诊断逻辑修正，非渲染路径改动）：
  - 新增 `frame_publish_count_` 成员；`PublishFrame` 改为前 10 帧每帧打像素
    统计（`帧#N 像素统计：非黑占比=…`），暴露「从黑到亮」过渡或确认「永远黑」。
  - 首个「非黑」帧才触发：色彩参数日志 + BMP 转储 + 「首个非黑帧已渲染上屏」
    标记；pre-decode 空帧不再占用首发诊断。
  - 判别方式：轻扫源缓冲前 4096 像素，RGB 和 >48 判定为有内容。
- 待复测：看到 `帧#N` 序列即定性——首帧 0%、后续转为有内容 = 仅首帧上屏时序
  问题（实际有画面）；1~10 帧恒 0% = 渲染管线始终未产出真实像素（需继续查
  mpv 解码 / SW 转换链路）。

## 3.1889 Windows 安装器「脏环境装不上」根治（错误码 5 @ 55%）

线上复现：安装到 55%（`extract` 阶段过半、卡片显示「部署 Node 引擎」）时报
「尝试替换已存在的文件时出错：DeleteFile 失败；错误代码 5。拒绝访问。」并回滚。
根因三段叠加，逐段落掉：

1. **占用**：`<app>\pyruntime\python.exe`（或 noderuntime）被常驻进程当映像加载
   → `DeleteFile` = ERROR_ACCESS_DENIED(5)。
2. **清理静默失效**：`[Code]` 里 `Exec('powershell.exe','-Command ... -like "C:\x\*"')`
   —— Inno 把参数原样拼进命令行，PowerShell 把 `-Command` 后的内容**当脚本重新
   解析**，那一层吃掉所有双引号（单引号包住也保不住）→ 收到 `-like C:\x\*`
   → ParserError → 退出码 1 → **一个进程都没杀**。WMI 分支同病
   （`-Filter "Name='python.exe'"` 引号被吃 → 无效 WQL）。
3. **无法重启替换**：`PrivilegesRequired=lowest`，排 `PendingFileRenameOperations`
   需写 HKLM → 失败 → 致命框 + 回滚。

修复：

- `windows/installer/kill-runtime.ps1`（新增）：清理脚本，随包 `dontcopy` 释放到
  `{tmp}`，由 `[Code]` 用 `-File ... -AppDir "<dir>"` 调用（argv 正常传参，引号不丢）。
  脚本内部同时覆盖「Get-Process 快路径」与「CIM 兜底」，并打印 killed/failed 明细。
- `windows/installer/installer.iss`：
  - `KillVboxProcesses` 改为「taskkill vbox.exe + 三轮脚本清理 + 每轮改名探测」，
    最多三轮，解锁即退出；`UseWmi` 形参保留以兼容卸载调用点。
  - ⚠ **改名/删除探测不可靠（3.1889 实测推翻）**：Windows 允许给正在运行的 exe
    改名，甚至允许 DeleteFile（映像 section 以 FILE_SHARE_DELETE 打开，名字删了
    进程照跑）。所以「改得动 = 可覆盖」是错的判据；只有真去覆盖才会暴露
    「有别的句柄不共享删除」。现改为**按进程是否存在**判断（`tasklist` + `find`）。
  - `PrepareToInstall`：先发优雅退出请求等 8s → 仍不退才强制清理 → 之后仍不退就
    `Result := '人话提示'`，不让用户在 55% 收到错误码 5。
  - ⚠ 注意 Inno Pascal 注释 `{ }` 内不能再出现花括号（`{app}` 会提前闭合注释）。
- `windows/setup-shell/MainWindow.xaml.cs`：安装日志从临时工作目录改到
  `%LOCALAPPDATA%\vbox-setup-logs\vbox-setup-<时间戳>.log`（保留最近 10 份）——
  旧实现日志在工作目录里，窗口一关即被 `CleanupTemp` 删除，线上故障现场全丢。
- `scripts/smoke/win-installer-dirty-env.ps1`（新增）：脏环境冒烟——正常装一遍 →
  起进程锁住 `pyruntime\python.exe` → 再装一遍 → 断言 exit 0。CI 可直接调用。

验证记录（本机）：Inno Setup 6.7.3 编译通过；`dotnet build` 壳 0 警告 0 错误；
脏环境端到端日志 `KillVboxProcesses: 运行时文件已解锁（第 1 轮）` +
`Installation process succeeded.`；冒烟脚本 PASS。

待办：运行时目录版本化（`{app}\runtime\python\<ver>\`）可让升级彻底不依赖杀进程，
涉及 `python_runtime.dart` 的候选探测与 `[Files]` 布局，单独 PR 处理。

## 3.1889 补充：方案 D「应用自己先退」（对齐 QQ / 微信 / Discord）

强杀只能靠猜，猜漏就装不上（3.1888 线上即如此：vbox.exe 已退出，pid 残留的
python 仍借着自己那份解释器占着 `pyruntime\python.exe`）。大厂通行做法是让应用
自己先退，本版落地：

- `windows/installer/installer.iss`：`PrepareToInstall` 先写标记文件
  `<app>\.vbox-upgrade-request`，最多等 8s（`tasklist` 轮询 vbox.exe 是否消失）；
  超时才 `KillVboxProcesses`（taskkill + kill-runtime.ps1）。`AnyRuntimeProcess()`
  在「机器上一个 node/python 都没有」时跳过清理，省几秒。标记在 `ssPostInstall`
  与 `DeinitializeSetup` 清除（失败/取消也要清，否则下次启动会被当成升级请求）。
- `lib/platform/update/upgrade_handshake.dart`（新增）：每秒轮询标记；发现后停
  `NodeRuntimeManager`、`exit(0)`。早于启动前 30s 的标记视为上次残留，忽略并删除。
- `lib/main.dart`：Windows 启动时 `UpgradeHandshake.start()`。
- `lib/platform/spider/python_runtime.dart`：Python 子进程也 `attach` 到主进程的
  Job Object（`com.vbox.node/lifecycle`），主进程退出时由 OS 连带终结——这是
  「vbox.exe 崩了留一堆 python」的根治，也让优雅退出真正干净。

端到端验证（本机）：
- 配合型假应用（真起 python 子进程 + 看标记自退）：安装器 640ms 内检测到退出，
  安装成功，全程未强杀。
- 崩溃残留型（只有 python 僵尸、无 vbox.exe）：走强制清理，安装成功。
- 两者 exit=0；正常情况下用户只需点「安装」，应用自动退出、装完自动起。
## 3.1890 Windows「不管播什么都一卡一卡」根因修复

用户反馈：云电脑与家用电脑**都一样卡**，与片源无关。定位到三个叠加项，
都出自同一条渲染管线的假设——「渲染目标恒等于窗口物理尺寸」。

1. **每帧全尺寸 GPU→CPU 同步回读**（`player_plugin.cpp:1775-1796`）：
   `glFinish()` 等 GPU 全流水线排空 → `glReadPixels` 整帧下 PCIe →
   Flutter 再上传回 GPU。4K 下每帧 33 MB×2，两次同步，任何显卡都抖。
   家里物理机卡在这条，与显卡强弱无关。
2. **每帧新建 `std::vector scratch`**：33 MB 的 malloc/memset/free 抖动。
3. **云电脑退化成纯 CPU**：`SM_REMOTESESSION` → `prefer_software_render_`
   （`:889`）→ 旧代码再 `hwdec="no"`（`:608`），libswscale 在 CPU 上做
   全尺寸 YUV→BGRA 缩放。
4. **没设 `framedrop`**：mpv 默认不丢帧，追不上就把时间往后拖——一卡一卡
   且音画渐行渐远。

本版改动：

- `lib/presentation/widgets/player/video_surface.dart`：把 `Texture` 的**布局
  尺寸钉在长边 ≤ 1920 物理像素**（`kMaxTextureLongSide`），再用 `FittedBox`
  缩放/裁切到播放区。引擎按布局尺寸回调 `CopyPixelBuffer`，于是原生每帧字节
  数从 33 MB（4K）降到 8.3 MB，缩放改由合成器一次四边形完成。
  ⚠ 注意：`ar` 的类型提升不能靠 `hasAspect` 这个 bool，条件必须内联写。
- `windows/runner/player_plugin.cpp`：
  - `framedrop=vo`、`vd-lavc-threads=0`（auto）。
  - SW 档位 `hwdec` 从 `no` 改为 `auto-safe`（硬解初始化失败由 mpv 回退软解；
    可用时拿到硬解，4K 软解过载缓解）；`VBOX_HWDEC` 覆盖新增 `auto-safe`。
  - SW 档位显式 `dither-depth=no` / `deband=no`（GPU 缩放器在 SW 下本就不生效，
    这两项仍在 CPU 跑）。

验证：Dart 侧由 CI `flutter-analyze` 把关；C++ 侧本机无 Flutter SDK 无法编译，
需 CI `build-windows` 验证。**待办**：把每帧 `std::vector scratch` 换成成员缓冲
复用 + PBO 双缓冲异步回读（去掉 `glFinish` 停等），那是家机能否真正「顺」的
分水岭；更彻底是让 mpv 直接输出子窗口（PlatformView），零回读零上传。