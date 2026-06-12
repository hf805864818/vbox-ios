# MPV framework 与依赖放置说明

这个目录只服务播放器 MPV 内核开发。现阶段不改切片资源播放、网盘资源播放、弹幕系统和播放器 UI 主流程。

## 当前边界

当前只处理 MPV 内核和依赖：

```text
1. 不接管现有 PlayerViewsV2 正式播放链路
2. 不改网盘资源和切片资源解析
3. 不接入弹幕系统
4. 不重构播放器 UI
5. 不提前 Link/Embed 未验证完整的 MPV 依赖
```

后续会为切片资源、网盘资源、弹幕和 UI 重构预留接口，但不在当前阶段实现。

## 当前文件

```text
MPVKit.xcframework
```

这是基于 `mpvkit/MPVKit` 封装出的 wrapper framework，模块名为：

```swift
import MPVKit
```

该 framework 是动态 framework。`3.143` 中曾直接 Link + Embed，但 App 启动闪退，说明 wrapper 的底层链接链路尚未验证完整。

从 `3.144` 开始，工程先保留文件，但暂时不 Link、不 Embed：

```text
保留：vbox/Libraries/MPV/MPVKit.xcframework
暂不：Link Binary With Libraries
暂不：Embed & Sign
```

后续补齐官方依赖后，再重新启用 Link + Embed。

`3.145` 增加了 `MPVFrameworkManifest.swift` 作为静态预检清单。它只记录模块名、路径、依赖和启用条件，不 import MPVKit，也不触发动态库加载。后端不可用提示统一从这份清单读取，避免后续接入时状态说明散落在多个文件中。

`3.146` 增加依赖包检查与安装准备脚本：

```text
scripts/inspect_mpvkit_bundle.py
scripts/install_mpv_dependencies.sh
```

上传的 `MPVKit-xcframework.zip` 外层包含 `MPVKit-binary-bundle.zip` 和 sha256 文件。该 bundle 已确认包含核心依赖：

```text
Libmpv.xcframework
Libavcodec.xcframework
Libavdevice.xcframework
Libavfilter.xcframework
Libavformat.xcframework
Libavutil.xcframework
Libswresample.xcframework
Libswscale.xcframework
```

它不是完整离线 Swift Package 依赖包。`Package.swift` 还声明了需要从 GitHub 下载的 binaryTarget，包括但不限于：

```text
Libcrypto
Libssl
Libass
Libbluray
Libuchardet
MoltenVK
Libplacebo
Libdav1d
gnutls
```

## 建议目录

核心依赖安装目标：

```text
vbox/Libraries/MPV/
├── MPVKit.xcframework
├── Dependencies/
│   ├── Libmpv.xcframework
│   ├── Libavcodec.xcframework
│   ├── Libavdevice.xcframework
│   ├── Libavfilter.xcframework
│   ├── Libavformat.xcframework
│   ├── Libavutil.xcframework
│   ├── Libswresample.xcframework
│   └── Libswscale.xcframework
└── README.md
```

`Libmpv.xcframework` 的模块名是：

```swift
import Libmpv
```

不是：

```swift
import libmpv
```

## UI 命名

```text
MPV    = MPVKit.xcframework
自由度 = Libmpv.xcframework
```

## 架构要求

必须包含 `ios-arm64`。推荐包含 `ios-arm64_x86_64-simulator`，方便后续模拟器验证。

## 接入规则

在完整依赖链路验证之前，不要提前把 MPV 相关 framework 加入 Xcode 的 `Link Binary With Libraries` 或 `Embed Frameworks`。

真实接入时需要确认：

```text
1. framework 的模块名，尤其是 `Libmpv`
2. Info.plist 支持的架构 slice
3. Swift Package binaryTarget 是否能被 GitHub Actions 下载
4. 手动 Link 时是否需要补齐所有间接依赖
5. 是否需要 Embed & Sign
6. 启动是否仍然闪退
```

## 体积建议

如果 `.xcframework` 很大，建议使用 Git LFS 或构建时从 Release 下载，不建议直接普通提交超大二进制。

## 冲突提醒

不要随意同时启用多个都内置 FFmpeg/libmpv 的大型 framework。MPVKit wrapper、Libmpv 和 FFmpeg 组件之间要先确认链接关系，避免重复符号或运行时冲突。
