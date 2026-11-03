# Flutter 端播放器内核开发方案（VBox）

> 目标：在不改动现有播放器 UI 的前提下，用长期稳定、跨平台成熟的内核替换 Windows 端自研 mpv 渲染桥，根治「云电脑/无 GPU 环境有声无画」问题，并把三端播放内核抽象对齐 iOS 端成熟体系。
>
> **版本：v1.2** · 日期：2026-10-18

---

## 变更记录（Changelog）

| 版本 | 变更点 |
|------|--------|
| v1.0 | 初版：选型 media_kit，自研桥作降级兜底 |
| **v1.1** | ① 自研桥策略由「降级兜底」改为「**退役**」（降级到必然黑屏的内核无意义）；② 补充 uzVideo 媒体内核的逆向分析结论（media_kit 配置 / ANGLE 渲染 / 起播调优），作为落地的配置基线 |
| **v1.2** | 落地实施（Phase 0/1）：接入 media_kit 依赖、新增 `MediaKitPlayer` + `media_kit_profile`、`PlayerBackend.mediaKit`、链收敛为单内核；并按 media_kit 2.x 真实 API 校正 §5.2 草图（见附录 §10） |

---

## 0. 结论速览（TL;DR）

1. **根因**：不是云电脑，而是 vbox Windows 端「自研 mpv 渲染桥」选错渲染路线（OpenGL 离屏 FBO + libswscale 软渲染），且软渲染路径带 FRAME/pixelformat 两个回归闸门。云电脑无真 GPU 时该路线**架构上走不通**，故有声无画。
2. **选型**：Windows/macOS 端用 **`media_kit`（底层 libmpv + ANGLE/D3D11 渲染）** 作为唯一主内核，这正是 uzVideo 在云电脑上能正常播放的同款方案。
3. **自研桥退役**：不再作为兜底（坏兜底无意义），从播放链移除，验证稳定后物理删除。
4. **UI 零改动**：复用现有 `Player` 抽象 + `PlayerController`，新增 `MediaKitPlayer` 实现并挂为唯一内核，`Texture(textureId)` 上屏逻辑完全复用。
5. **长期稳定**：对齐 iOS「统一 `Player` 抽象 + 按媒体类型调优」；media_kit 社区最活跃、跨平台，未来可统一三端内核。

---

## 1. 现状分析

### 1.1 现有 Flutter 播放器三层（已设计良好，无需推翻）

| 层 | 文件 | 职责 |
|----|------|------|
| UI | `lib/presentation/pages/player/player_page.dart` | 通过 `PlayerController` 驱动；挂载 `Texture(textureId)` 上屏 |
| 控制 | `lib/platform/player/player_controller.dart` | `PlayerController`：`_openWithChain` 后端链/`switchBackend`/`onSurfaceChanged`/运行期错误处理 |
| 桥接 | `lib/platform/player/channel_player.dart` + `player_channel_bridge.dart` | `ChannelPlayer implements Player`；经 `com.vbox.player/player` + `.../events` 调原生 |

`Player` 抽象（`lib/domain/entities/player/player.dart`）关键接口：

```dart
abstract interface class Player {
  PlayerBackend get backend;
  int? get textureId;
  List<PlayerBackend> get availableBackends;

  Future<void> open(PlayerSource source);
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(int positionMs);
  Future<void> setVolume(double volume);
  Future<void> setSpeed(double speed);
  Future<void> dispose();

  void Function(PlayerState)? onStateChanged;
  void Function(PlaybackProgress)? onProgress;
  void Function(int width, int height)? onVideoSize;
  void Function(int textureId)? onTextureReady;
  void Function(String message, {required bool fatal})? onError;
}
```

事件面统一 6 类：`state` / `progress` / `error` / `videoSize` / `textureReady` / `log`。

### 1.2 问题根因（Windows 端）

- 自研 `windows/runner/player_plugin.cpp` 仅两条渲染路：**OpenGL 离屏 FBO 回读**（需 OpenGL 2.0+）与 **libswscale 软渲染**兜底。
- 云电脑仅 `OpenGL 1.1`（软件实现），FBO 建不起来 → 被迫软渲染；软渲染又命中 3.1859 引入的 FRAME/pixelformat 闸门 → 真实帧永不推上屏。
- 音频走 `wasapi` 不依赖闸门 → **有声无画**。
- **关键研判**：自研桥的根问题不在「闸门 bug 可修」，而在「其渲染路线从架构上依赖 OpenGL FBO，云电脑上走不通」——因此修闸门也无法在云电脑恢复画面，自研桥应直接退役而非修补兜底。

---

## 2. uzVideo 与 iOS 端对比（选型依据）

### 2.1 uzVideo 媒体内核逆向分析

#### 2.1.1 技术栈定性（app.so 字符串 + DLL 清单）

| 证据 | 结论 |
|------|------|
| `media_kit`(8)/`MediaKit`(3)/`media_kit_video`(1) | 主内核是 **media_kit** |
| `libmpv`(11)/`LIBMPV`(1)、`libmpv-2.dll`(38M)、`ffmpeg-9.dll`(12M) | 底层就是 **libmpv** |
| `mdk_sdk`(0)/`MdkPlayer`(0) | mdk-sdk **非主内核**（`mdk.dll`/`fvp.dll` 仅为历史/备选残留） |
| `media_kit_video_plugin.dll` + `media_kit_libs_windows_video_plugin.dll` | Windows 输出插件 = media_kit_video |

#### 2.1.2 配置细节（mpv/libmpv 选项痕迹）

| 痕迹 | 命中 | 推导出的 uz 配置策略 |
|------|------|---------------------|
| `VideoController` / `media_kit_video` | 3 / 1 | 用 `Video(controller)` 输出纹理，与 vbox 的 `textureId` 抽象一致 |
| `enableHardwareAcceleration` | 1 | `VideoControllerConfiguration(enableHardwareAcceleration: true)`，尝试硬解 |
| `d3d11` / `D3D11` / `hwdec` | 各 1 | Windows 硬解走 **d3d11va**，失败自动回退软解 |
| `angle` | 1 | **渲染走 ANGLE（D3D11 之上的 OpenGL ES）**，无真 GPU 时自动落到 D3D11 WARP 软件光栅化 → 云电脑正常出画面（这正是自研桥缺的一环） |
| `hr-seek` | 2 | 精确 seek（`hr-seek=yes`），拖动定位更准 |
| `demuxer-max` / `demuxer-readahead` | 2 / 1 | 起播/边播边下缓存调优（`demuxer-max-bytes`、`demuxer-readahead-secs`） |
| `VAAPI` | 1 | Linux 硬解回落（跨平台硬解链） |

**结论**：uz 的做法 = media_kit `Player` + `VideoController`（开硬解）+ libmpv 走 ANGLE/D3D11 渲染 + `hr-seek`/`demuxer` 起播调优。**渲染交给操作系统级的 D3D11/WARP，不依赖应用自建 OpenGL FBO**。

#### 2.1.3 与 vbox 现状的对比

| 端 | 内核 | 渲染 | 云电脑 |
|----|------|------|--------|
| iOS vbox | MPVKit / MoltenVK / MDK | Metal / MoltenVK | 无此场景 |
| Windows vbox（现状） | 裸 `libmpv-2.dll` + 自研桥 | OpenGL FBO / libswscale | ❌ 黑屏 |
| Windows uzVideo | **media_kit + libmpv** | **ANGLE / D3D11（WARP 兜底）** | ✅ 正常 |

### 2.2 iOS 端为什么「成熟」

不是某个内核强，而是**架构成熟**（`vbox/PlayerCore/`）：统一 `PlayerEngine` 抽象 + `PlayerEngineController` 多内核切换（AVPlayer/MPVKit/MoltenVK/MDK）+ 渲染交给 Metal/MoltenVK 现成层 + 按媒体类型 `PlaybackProfile` 调优。Flutter 端要复刻的正是这套「统一抽象 + 调优」。

---

## 3. 技术选型决策

**选择 `media_kit` 作为 Windows/macOS 唯一主内核。** 理由：

1. **uz 同款、云电脑实战验证**：ANGLE/D3D11 渲染天然容错无 GPU 环境。
2. **纯 Dart + 原生纹理**：`Video(controller)` 直接产出 `textureId`，与现有 `Player.textureId` 无缝契合。
3. **长期稳定、社区最活跃、三端覆盖**：Windows/macOS/Linux/Android，未来可统一内核、降低维护面。
4. **配置基线可用 uz 逆向结果直接落地**：开硬解 + hr-seek + demuxer 缓存，无需从零调。

> 弃用备选：mdk-sdk/fvp —— uz 实际主内核是 media_kit（`mdk_sdk` 命中共 0），且 media_kit 社区/文档更完善。

**自研桥处置（v1.1 修正）**：不修复、不作兜底，**直接退役**。理由：其渲染架构依赖 OpenGL FBO，云电脑上走不通；降级到一个必然黑屏的内核没有意义。

---

## 4. 目标架构

```
┌─────────────────────────────────────────────┐
│  UI 层（保持不变）                             │
│  player_page.dart → PlayerController         │
│  Texture(textureId) 上屏                     │
└───────────────────┬─────────────────────────┘
                    │ onSurfaceChanged(textureId)/状态/进度
┌───────────────────▼─────────────────────────┐
│  控制层 PlayerController（收敛为单一内核）      │
│  open → MediaKitPlayer（唯一实现）            │
│  保留 switchBackend/错误处理骨架（兼容未来扩展）│
└───────────────────┬─────────────────────────┘
                    │
        ┌───────────▼───────────┐
        │ MediaKitPlayer        │
        │ (implements Player)   │
        │ media_kit Player      │
        │ + VideoController     │
        │ + ANGLE/D3D11 渲染    │
        └───────────────────────┘

  已退役：ChannelPlayer + windows/runner/player_plugin.cpp（自研桥）
```

要点：**内核收敛为 media_kit，纯 Dart 直连（不经 MethodChannel）**；自研桥从 `_backendChain` 移除。

---

## 5. 详细设计

### 5.1 新增枚举值 & 收敛后端链

- `PlayerBackend` 新增 `mediaKit`（`backendWireValue` 返回 `"media_kit"`）。
- `PlayerController._backendChain` 在 Windows/macOS 收敛为单元素 `[PlayerBackend.mediaKit]`；`_openWithChain` 分派：`mediaKit` → `MediaKitPlayer`，其余分支冻结/移除。

### 5.2 核心实现：`MediaKitPlayer`（对齐 uz 配置基线）

新建 `lib/platform/player/media_kit_player.dart`：

```dart
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class MediaKitPlayer implements Player {
  MediaKitPlayer({required this.backend}) {
    _mpv = Player();                 // 底层 libmpv
    _controller = VideoController(_mpv,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,   // 尝试 d3d11va，失败自动软解
      ),
    );
    _applyTuning();                  // hr-seek / demuxer 起播调优（对齐 uz）
    _bindStreams();
  }

  final PlayerBackend backend;
  late final Player _mpv;
  late final VideoController _controller;

  @override
  int? get textureId => _controller.textureId;

  @override
  Future<void> open(PlayerSource source) async {
    await _mpv.open(Media(source.url, httpHeaders: source.headers), play: false);
  }

  @override
  Future<void> play() => _mpv.play();
  @override
  Future<void> pause() => _mpv.pause();
  @override
  Future<void> seekTo(int positionMs) =>
      _mpv.seek(Duration(milliseconds: positionMs));
  @override
  Future<void> setVolume(double v) => _mpv.setVolume(v);
  @override
  Future<void> setSpeed(double s) => _mpv.setRate(s);
  @override
  Future<void> dispose() async => _mpv.dispose();

  // 对齐 uz 的 libmpv 调优项
  void _applyTuning() {
    _mpv.setProperty('hr-seek', 'yes');            // 精确 seek
    _mpv.setProperty('demuxer-max-bytes', ...);    // 起播缓存
    _mpv.setProperty('demuxer-readahead-secs', ...);
  }

  void _bindStreams() {
    _mpv.stream.position.listen(...);   // → onProgress（合并 duration/buffered）
    _mpv.stream.duration.listen(...);
    _mpv.stream.playing.listen((b) => onStateChanged?.call(
        b ? PlayerState.playing : PlayerState.paused));
    _mpv.stream.error.listen((s) => onError?.call(s, fatal: true));
    _mpv.stream.width.listen((w) { /* 结合 height 发 onVideoSize */ });
    _controller.stream.textureId.listen((id) => onTextureReady?.call(id));
  }
  // 回调字段语义与 ChannelPlayer 保持一致
}
```

### 5.3 `PlayerController` 改动点（最小）

- 链头固定 `mediaKit`，移除自研桥成员。
- 创建内核时：`backend == PlayerBackend.mediaKit` → `MediaKitPlayer`（其余分支保留代码但不再被选中，便于未来加回多内核）。
- `switchBackend`、`_handleRuntimeError`、`onSurfaceChanged` 挂载、事件转发**保持不变**——表面仍是 `Player` 抽象。

### 5.4 渲染与稳定性配置

- 渲染交给 media_kit/libmpv 的 **ANGLE/D3D11**（内部处理；无真 GPU 自动 WARP 软件光栅化），**禁用**自研桥的 `vo=libmpv`/FBO/`glReadPixels` 路线。
- 加一个 `media_kit_profile.dart`（对齐 iOS `PlaybackProfile`），按源类型下发 `cache`/`demuxer` 选项：HLS 直播（低起播延迟）、大 MKV（增大 readahead）、常规流畅播等。
- 日志：把 `_mpv.stream.log` 桥到应用日志，复用现有 `log` 事件口径，保证无画面问题可定位（对齐 iOS 排障详细度）。

---

## 6. 长期稳定策略

1. **`Player` 抽象稳定**：UI 只依赖 `PlayerController` + `Player`，内核可换 UI 不动。
2. **单一内核 + 可扩展骨架**：当前收敛 media_kit，但 `_openWithChain`/`switchBackend` 骨架保留，未来遇 media_kit 覆盖不到的特殊源可再插内核，无需改 UI。
3. **配置调优对齐 uz/iOS**：`enableHardwareAcceleration` + `hr-seek` + `demuxer` 缓存 + `PlaybackProfile`。
4. **资源生命周期**：`dispose` 释放 `Player`+`VideoController`；切换内核先 `_disposePlayer` 再重开。
5. **自研桥退役预案**：仅移除运行时链，物理代码先留 git；media_kit 全场景验证稳定后再删 `player_plugin.cpp` 与自带 `mpv-2.dll`。

---

## 7. 分阶段实施计划

| 阶段 | 内容 | 交付/验收 |
|------|------|-----------|
| **Phase 0** 依赖接入 | `pubspec` 加 `media_kit`+`media_kit_video`+`media_kit_libs_video`；CI 编译过 | Windows/macOS 编译通过 |
| **Phase 1** 内核实现 | 新增 `MediaKitPlayer`、`PlayerBackend.mediaKit`、`media_kit_profile.dart` | 单机 URL 有声有画 |
| **Phase 2** 链收敛 | `PlayerController` 收敛为 mediaKit，移出自研桥 | 正常播放、无自研桥参与 |
| **Phase 3** UI 回归 | 播放页全功能回归（进度/手势/倍速/音轨/字幕/全屏/弹幕/投屏） | UI 零改动、功能零回退 |
| **Phase 4** 无 GPU 验证 | 云电脑/远程桌面实测 | 有声有画、色彩可接受 |
| **Phase 5** 退役清理 | 验证稳定后物理删除自研桥 + 自带 `mpv-2.dll` | 代码/依赖清理干净 |

---

## 8. 验收标准

- [ ] Windows 云电脑（无真 GPU）播放任意源：**有声有画**。
- [ ] 现有播放器 UI 功能零回退（进度/手势/全屏/倍速/音轨/字幕/弹幕/投屏）。
- [ ] 硬解不可用时自动回退软解，不卡死、不黑屏。
- [ ] 播放器 `dispose` 无资源泄漏（内存/纹理句柄）。
- [ ] 出错时日志可定位失败节点（对齐 iOS 排障详细度）。
- [ ] 自研桥不再参与播放（链中无 `ChannelPlayer`/自研 backend）。

---

## 9. 关键文件清单

| 类型 | 路径 | 说明 |
|------|------|------|
| 新增 | `lib/platform/player/media_kit_player.dart` | media_kit 内核实现（对齐 `Player` + uz 配置） |
| 新增 | `lib/platform/player/media_kit_profile.dart` | 按媒体类型调优（对齐 iOS profile） |
| 修改 | `lib/domain/entities/player/player.dart` | `PlayerBackend` 枚举加 `mediaKit` |
| 修改 | `lib/platform/player/player_controller.dart` | 收敛为 mediaKit 单内核、移出自研桥 |
| 修改 | `pubspec.yaml` | 加 media_kit 系列依赖 |
| 退役 | `windows/runner/player_plugin.cpp`、`windows/third_party/mpv-2.dll` | 运行时移除，验证后物理删除 |
| 保持 | `lib/presentation/pages/player/*` | UI 层不动 |
| 保持 | `lib/platform/player/channel_player.dart` 等 | 冻结留存，暂不参与播放 |

---

## 10. 实施落地记录（v1.2 · Phase 0/1）

已按本方案完成 Phase 0/1（含链收敛）落地，代码位于本仓库：

| 动作 | 文件 | 说明 |
|------|------|------|
| 新增 | `lib/platform/player/media_kit_player.dart` | `MediaKitPlayer implements Player`，纯 Dart 直连 media_kit |
| 新增 | `lib/platform/player/media_kit_profile.dart` | 按源类型下发 demuxer 缓存 / 预读（对齐 iOS `PlaybackProfile`） |
| 修改 | `lib/domain/entities/player/player.dart` | `PlayerBackend` 新增 `mediaKit`；`chainFor` windows/macos 收敛为 `[mediaKit]`；`Player` 接口补 `onTextureReady` |
| 修改 | `lib/platform/player/player_controller.dart` | `_player`/`_attach`/`_disposePlayer` 泛化为 `Player`；新增 `_createPlayer`（mediaKit→MediaKitPlayer，其余保留 ChannelPlayer 兜底骨架） |
| 修改 | `lib/platform/player/player_channel_bridge.dart` | `backendWireValue` 补 `mediaKit => 'media_kit'` |
| 修改 | `lib/platform/player/channel_player.dart` | 通道桥 `onTextureReady` 字段补 `@override`（接口一致性，无行为变化） |
| 修改 | `pubspec.yaml` | `media_kit ^1.2.6` + `media_kit_video ^2.0.1` + `media_kit_libs_video ^1.0.7` |
| 修改 | `test/platform/player/player_backend_selector_test.dart` | windows/macos 链断言同步为 `[mediaKit]` |

**对 §5.2 草图的 API 校正**（media_kit 2.x 真实接口，落地按此实现）：

| §5.2 草图 | v1.2 落地 |
|-----------|-----------|
| `_controller.textureId` | `VideoController.id.value`（`ValueNotifier<int?>`，纹理懒注册） |
| `_controller.stream.textureId` | `_controller.id.addListener(...)` 后触发 `onTextureReady` |
| `_mpv.setProperty(...)` | `(_mpv.platform as NativePlayer).setProperty(...)`（`setProperty` 非公开 `Player` 成员） |
| `_mpv.stream.log` 为 `String` | 实际为 `Stream<PlayerLog>`（按 `level` 分派到 `AppLog`） |
| `setVolume(v)` 直传 | `(v * 100).clamp(0, 100)`（`Player.setVolume` 契约 0~1 → media_kit 0~100） |
| `stream.width/height` 为 `int` | 实际为 `Stream<int?>`（去空后合并发 `onVideoSize`） |
| 构造函数裸 `Player()` | 需先 `MediaKit.ensureInitialized()`（同步、幂等）再建 `Player` |

**验证依赖**：本机无 Flutter SDK，未做本地编译；CI 的 `flutter pub get`（非 `--frozen`）会自动解析 `pubspec.lock` 并更新，`flutter analyze` / `flutter test` / `flutter build windows|macos|apk` 覆盖编译与回归验证。