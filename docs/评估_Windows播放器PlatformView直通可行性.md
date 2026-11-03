# 评估：Windows 播放器 mpv `wid` 直通（PlatformView 路线）根治画面问题的可行性

> 版本 v1.0 · 2026-10-16
> 状态：评估（未立项实施）
> 关联提交：`5103651`（现状版画面修复）、`0edcaf1`（百度取号内置 WebView2）
> 结论性质：本文为技术决策输入，是否实施待确认。

---

## 0. TL;DR（结论先行）

1. **换内核不能根治**：mpv / libVLC / FFmpeg 最终都要把画面塞给 Flutter 的
   `PixelBufferTexture`（只收 CPU BGRA），泛黄/发虚/闪退的风险点在这座
   「CPU 回读桥」上，与内核无关。mpv 在缩放/色彩质量上本就是最优选，换掉是降级。
2. **唯一能根治的路**：绕开 Flutter 外部纹理桥，让 mpv 用 `wid` 直通一个原生
   `HWND`（GPU 零拷贝），对齐 iOS 的 `wid → CAMetalLayer`。
3. **关键技术风险**（决定这事能不能做）：Flutter 在 **Windows / Linux / macOS
   桌面端至今没有官方生产级 PlatformView**。GitHub issue #31713
   「Absence of official Platform View APIs in Flutter for Windows, Linux & macOS」
   多年未落地；Flutter 官方文档《Desktop Platform Views Framework API Boundary》
   明确把 Windows/Linux 的实现列为 **non-goal**。仅存在 `internal` 头文件里的
   不稳定接口。
4. **可落地的替代**：用公开嵌入器 API `FlutterDesktopViewGetHWND` 拿到主窗口
   HWND，自己用 Win32 建一个子 HWND 盖在播放区域上、mpv `wid` 直通到它
   （即「原生子窗口覆盖」，第三方 `flutter_native_view` 就是这个原理）。
5. **建议**：先验证现状版（v3.1856/3.1857，已把回读折损压到可用）；确需
   根治，优先走「子窗口覆盖 + flutter_native_view 加速」，不建议硬啃内部
   PlatformView API。

---

## 1. 背景与问题

Windows 端所有资源（站源/网盘）播放均出现三类画面问题，而 iOS 端正常：

| 现象 | 现状版已修程度 |
|---|---|
| 泛黄 / 偏色 | 双路径钉 `target-prim/trc` + FBO 回读自检，基本可控 |
| 发虚 / 摩尔纹 | 按显示尺寸渲染、缩小交给 mpv 缩放器，基本可控 |
| 播放闪退 | `FilterQuality` 回退 low，基本可控 |

**但这些都是「在内核与回读桥里打补丁」，没有消除结构性问题。**

---

## 2. 现状架构：为什么「补丁」打不完

Windows 端的画面链路（[player_plugin.cpp](file:///workspace/vboxapp/windows/runner/player_plugin.cpp)）：

```
解码 → mpv 离屏渲染到 GL FBO（或 SW 软渲染）
     → glReadPixels 回读到 CPU（原始 BGRA 字节）
     → Flutter 纹理 buffer（PixelBufferTexture）
     → Flutter 引擎再上传 GPU → 屏幕
```

多了一次「GPU → CPU → GPU」往返。原因见 [video_surface.dart](file:///workspace/vboxapp/lib/presentation/widgets/player/video_surface.dart)
与 [channel_player.dart](file:///workspace/vboxapp/lib/platform/player/channel_player.dart)：
Flutter Windows 桌面引擎给原生端的公开接口只有 `TextureRegistrar` + 外部纹理，
**只接受 CPU 内存的 pixel buffer**，没有像 iOS 那样的「塞原生 GPU 纹理」入口。

要点：问题出在「桥」，不在 mpv，也不在 Windows 本身。

---

## 3. iOS 为什么没问题（对齐基准）

[iOS 渲染绑定](file:///workspace/vboxapp/vbox/PlayerCore/MPVKitRenderedPlayerCore.swift#L110)：

```swift
check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &renderView.metalLayer), context: "wid")
```

iOS 把 `CAMetalLayer` 直接作为 mpv 的渲染目标，视频像素全程在 GPU 内流转：

```
解码 → mpv GPU 渲染（primaries/gamma/tone-mapping 全管线）→ Metal drawable → 屏幕
```

**零 CPU 回读、零格式转换、零二次采样。** 这是要「对齐」的目标形态。

---

## 4. 可执行路径对比

### 路径 A：维持现状（TextureRegistrar 外接 CPU 纹理）—— 已在使用

- 优点：公开 API、稳定、跨 Flutter 版本向前兼容、Dart 侧改动最小。
- 缺点：结构性多一次 GPU↔CPU 往返，色彩/锐度/功耗/延迟有理论上限；偏色需靠
  后端自检与色彩钉扎兜底（已做）。
- 结论：**短期唯一稳妥项**，作为基线。

### 路径 B：Flutter Windows 内部 PlatformView API —— 不推荐

- 依赖 `flutter_windows_internal.h` 里的 `FlutterDesktopEngineRegisterPlatformViewType`
  与 `FlutterPlatformViewFactory`（返回 `HWND`）。
- 定性：**internal（内部）头文件**，非 `public/flutter_windows.h`，不属于稳定
  ABI，官方不承诺向后兼容，随 Flutter 版本可能改名/移除。
- 官方已把 Windows/Linux 的 PlatformView 生产验收列为 non-goal。
- 结论：**技术对齐最像 iOS，但地基是流沙**，生产环境不可用，不投入。

### 路径 C：原生 HWND 子窗口覆盖 + mpv `wid` 直通 —— 唯一可落地的根治

- 原理：不经过 Flutter 合成器，用公开嵌入器 API `FlutterDesktopViewGetHWND`
  拿主窗口 HWND，Win32 建一个子 HWND 盖在播放区域上方；mpv `wid` 直通到子
  HWND（内部走 D3D11/Vulkan GPU 直通，零回读）。
- 定性：这是 Flutter 桌面端在「官方 PlatformView 缺失」下的标准变通，与
  `flutter_native_view` 第三方包同原理。
- 优点：真正零回读，画面质量/性能对齐 iOS；内核继续用 mpv，完全不动 mpv 管线。
- 缺点：窗口管理坑极多（见 §5.3）。

---

## 5. 路径 C 详细设计（若立项）

### 5.1 总体架构

```
Flutter 引擎（Dart UI / 控制条 / 字幕 / 弹幕）
   └── 主窗口 HWND（FlutterDesktopViewGetHWND 公开获取）
         ├── Flutter 内容（控制条、进度、弹幕等 overlay 仍由 Flutter 画）
         └── 原生子 HWND（mpv 画面，wid 直通，覆盖在播放区域矩形上）
```

- mpv 侧：保留现有 [player_plugin.cpp](file:///workspace/vboxapp/windows/runner/player_plugin.cpp)
  的控制面（open/play/pause/seek/volume/speed）+ 事件面（state/progress/error），
  **只替换「画面输出面」**：去掉 `glReadPixels` + `PixelBufferTexture`，改为
  `mpv_set_option("wid", 子HWND)`。
- Dart 侧：[video_surface.dart](file:///workspace/vboxapp/lib/presentation/widgets/player/video_surface.dart)
  由 `Texture` 改为「占位盒 + 原生视图注册」；控制条/字幕仍叠在 Flutter 层。

### 5.2 关键接口

- **拿主 HWND**：`HWND FlutterDesktopViewGetHWND(FlutterDesktopViewRef view)`
  （`flutter_windows.h`，公开 API）。
- **建子 HWND**：`CreateWindowExW` 建 `WS_CHILD` 子窗口，父窗口 = 主 HWND，
  按播放区域矩形定位/缩放。
- **mpv 直通**：`mpv_set_property(mpv, "wid", MPV_FORMAT_INT64, (int64_t)子HWND)`。
  这与 iOS 的 `wid → CAMetalLayer` 完全同构。
- **可选加速**：第三方 `flutter_native_view`（pub.dev）已封装「把任意 HWND 嵌成
  Flutter Widget」，可省去大量坐标同步/生命周期样板，但需评估其维护活跃度与
  对当前 Flutter 版本（3.44+）的兼容性。

### 5.3 需要解决的窗口管理坑（风险清单）

| 坑 | 说明 | 复杂度 |
|---|---|---|
| z-order / 遮挡 | 原生子 HWND 恒在 Flutter 内容之上，会盖住控制条、字幕、弹幕、下拉手势 | 高 |
| 裁剪与圆角 | 全屏切换、播放器圆角、进出场动画时子窗口需同步裁剪 | 中 |
| 布局同步 | 拖拽/缩放/DPI 变化/多显示器时，子 HWND 必须实时跟随 Flutter 布局矩形 | 高 |
| 全屏/最小化 | 全屏窗口句柄变化、最小化时子窗口隐藏/销毁时机 | 中 |
| 输入事件 | 鼠标/触摸是否透传、控制条交互与视频区手势的边界 | 中 |
| 多实例 | 同时开多个播放页（画中画、列表预加载）时的多 HWND 管理 | 中 |
| PiP / 投屏 | 画面在子窗口外还需以纹理方式取帧（录屏/投屏/截图再走回读）| 高 |

> 提醒：路径 C 并非「一劳永逸」，部分能力（投屏、截图、录屏、PiP）可能仍需保留
> 一条「CPU 回读」旁路，等于两套画面输出并存，复杂度再上一个台阶。

### 5.4 Dart 侧改造

- `Player` 抽象新增「原生视图」语义（区别于 `textureId`）。
- `VideoSurface` 由 `Texture` 切换为原生视图占位/注册宿主。
- `ChannelPlayer.open` 返回值由 `textureId` 扩展为「视图类型 + 句柄/坐标」。

---

## 6. 路径取舍

| 维度 | A 现状 | B 内部 API | C 子窗口覆盖 |
|---|---|---|---|
| 画面根治 | 否（压到可用） | 是 | 是 |
| 稳定性 | 高（公开 API） | 低（internal） | 中（Win32 稳定，窗口管理自担） |
| 工作量 | 已完成 | 大且风险高 | 大 |
| 对齐 iOS | 弱 | 强 | 强 |
| 推荐 | 短期基线 | 否 | 若要根治的唯一选择 |

---

## 7. 工作量与风险分级

- **路径 C 核心链路（能出画面）**：中 —— 子 HWND 创建 + mpv `wid` 直通 +
  基础坐标同步，可在 1 个迭代内跑通 PoC。
- **路径 C 生产化（全覆盖坑清单）**：高 —— z-order、全屏、DPI、多实例、
  overlay、投屏/截图旁路，属架构级连续工程。
- **关键前置验证**：先用最小 PoC 验证「mpv wid 直通子 HWND 在目标机型
  （含云电脑/虚拟显卡）上是否真的零回读出正确色彩」，再决定是否投入生产化。

---

## 8. 建议

1. **第一步（不额外立项）**：装 v3.1856 / v3.1857 现状版，验证「泛黄/发虚/
   闪退」是否已被现有补丁压到可用。若可用，短期不动架构。
2. **若要彻底对齐 iOS**：立项路径 C，且**先做最小 PoC**（子 HWND + mpv wid
   直通，验证目标机型色彩正确），PoC 通过再评估生产化与 `flutter_native_view`
   选型。
3. **不建议**：换内核、以及啃 `flutter_windows_internal.h` 内部 PlatformView API。

---

## 附：参考来源

- Flutter GitHub issue #31713：Absence of official Platform View APIs in Flutter
  for Windows, Linux & macOS
- Flutter 官方文档《Desktop Platform Views Framework API Boundary》（NON-GOALS 节）
- Flutter Windows 嵌入器公开头 `flutter_windows.h`：`FlutterDesktopViewGetHWND`
- Flutter Windows 内部头 `flutter_windows_internal.h`：
  `FlutterDesktopEngineRegisterPlatformViewType` / `FlutterPlatformViewFactory`
- pub.dev `flutter_native_view`（把任意 HWND 嵌成 Flutter Widget，仅 Windows）