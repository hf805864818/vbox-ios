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

`3.147` 明确双后端依赖隔离：

```text
MPVKitDependencies/ 只服务 MPVKit.xcframework
Freedom/             只服务后续自由度 libmpv.xcframework
```

`3.148` 增加 GitHub Release 下载策略和已安装依赖检查：

```text
scripts/fetch_mpv_dependencies.sh
scripts/check_mpv_installed_dependencies.py
```

`3.149` 增加 CI 验证工作流，把 `fetch → install → check` 闭环搬到 GitHub Actions：

```text
.github/workflows/mpvkit-deps-check.yml
```

该工作流只验证 MPVKit 依赖闭环，不构建 Xcode 工程，不修改 Link/Embed。
触发条件：`workflow_dispatch`，或上述脚本本身发生变更的 `pull_request`。
同步增强 `scripts/fetch_mpv_dependencies.sh`：

```text
--cache-dir <dir>     指定缓存目录
--url <url>           指定下载地址
--sha256-url <url>    指定 sha256 地址
--skip-install        只下载与校验，不调用 install
```

缓存命中（本地压缩包 sha256 与远端一致）时跳过重复下载。

`3.150` 合入 MPVKit Link/Embed 自动验证能力：

```text
scripts/configure_mpvkit_link.rb
.github/workflows/build-ipa-debug.yml
```

`main` 的 `project.pbxproj` 不固化 9 个 framework 引用。CI 构建时先下载依赖，再用 Ruby `xcodeproj` gem 临时注入 `MPVKit.xcframework + Libmpv + FFmpeg 7 件套` 的 Link/Embed，archive 完成后丢弃该临时构建环境。

`3.151` 增加 App 内 MPVKit 运行时加载探针：

```text
MPVKitBackend.runtimeProbeResult
MPVIntegrationStatus.runtimeProbeSummary
设置 → 关于 → MPV状态
```

该探针只检查 `MPVKit.framework/MPVKit` 是否随包存在、是否能被 `dlopen` 动态加载，不创建 `mpv_handle`，不接正式播放 UI。

`3.152` 曾尝试增加 MPVKit 后端的最小内核初始化探针：

```text
MPVKitBackend.initializationProbeResult
MPVIntegrationStatus.initializationProbeSummary
设置 → 关于 → MPV状态
```

由于当前 `MPVKit.xcframework` 未暴露可直接调用的播放器 API，初始化探针曾尝试使用 `MPVKitDependencies/Libmpv.xcframework` 的 C API 执行：

```text
mpv_create → mpv_initialize → mpv_terminate_destroy
```

`3.154` 修正该策略：`Libmpv.framework/Libmpv` 实际是静态库 archive，不是动态库。直接 `import Libmpv` 并调用 `mpv_create` 会在链接阶段拉入完整静态依赖链，当前依赖包还缺 `gmp/libass/libbluray/lcms2` 等外部 binaryTarget，因此正式 IPA 暂不直接调用 `mpv_create`。

当前 App 内显示会保留：

```text
MPVKit-imported
MPVKit动态库已随包嵌入
动态加载成功
Libmpv-static
需补齐外部静态依赖后再初始化
```

后续要继续初始化，需要先补齐 Package.swift 中声明但未随 Release 包携带的外部依赖，再重新打开 `mpv_create → mpv_initialize` 探针。

`3.155` 修复 MPVKit 动态库文件名不一致导致的启动闪退：

```text
Library not loaded: @rpath/MPVKit.framework/MPVKitWrapper
```

`MPVKit.framework/Info.plist` 中 `CFBundleExecutable` 为 `MPVKit`，但动态库 install name 指向 `MPVKitWrapper`。正式 IPA 打包阶段会在 `MPVKit.framework` 内复制一份 `MPVKitWrapper`，避免 dyld 在启动时找不到该文件。

`3.156` 增加 Libmpv 静态依赖补齐检查和计划文档：

```text
vbox/Libraries/MPV/MPVKitDependencyPlan.md
scripts/check_mpv_installed_dependencies.py
```

检查脚本现在分两层：

```text
核心依赖：Libmpv + FFmpeg 7 件套，缺失时 CI 失败
外部静态依赖：gmp/libass/libbluray/lcms2 等，只提示缺失，不影响当前 CI
```

3.156 不重新打开 `import Libmpv`，也不调用 `mpv_create`。后续必须先补齐 `MPVKitDependencyPlan.md` 中列出的外部 binaryTarget，再进入 Libmpv 初始化。

`3.157` 增加外部静态依赖最小集自动下载：

```text
scripts/mpvkit_external_dependencies.json
scripts/fetch_mpv_external_dependencies.py
```

正式 IPA 和 Debug 验证 workflow 会在核心依赖安装后继续安装：

```text
gmp.xcframework
Libass.xcframework
Libbluray.xcframework
lcms2.xcframework
```

3.157 仍然不调用 `mpv_create`，只验证外部依赖能被下载、解压并进入 `MPVKitDependencies/`。

`3.158` 重新打开最小 Libmpv 初始化探针：

```text
import Libmpv
mpv_client_api_version
mpv_create
mpv_set_option_string(config=no / terminal=no / vo=null / ao=null)
mpv_initialize
mpv_terminate_destroy
```

同时 `scripts/configure_mpvkit_link.rb` 改为自动注入 `MPVKitDependencies/` 下已经安装的所有 `.xcframework`，并额外注入 `VideoToolbox/CoreMedia/CoreVideo/AudioToolbox/AVFoundation/Metal/Security/libz/libbz2/libiconv` 等系统依赖。

3.158 仍然不加载视频、不渲染、不接正式播放器 UI。若 CI 再次出现 `Undefined symbols`，继续按日志补第二批外部依赖。

MPVKit 依赖包默认来源：

```text
https://github.com/hf805864818/vbox-ios/releases/download/mpvkit-deps-0.0.1/MPVKit-xcframework.zip
```

这个地址只写在脚本和文档里，不写入 App Swift 运行代码。App 不在用户设备上下载 framework，依赖只在开发或 CI 构建前下载、解压和检查。

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

MPVKit 与自由度内核必须分开存放：

```text
vbox/Libraries/MPV/
├── MPVKit.xcframework
├── MPVKitDependencies/
│   ├── Libmpv.xcframework
│   ├── Libavcodec.xcframework
│   ├── Libavdevice.xcframework
│   ├── Libavfilter.xcframework
│   ├── Libavformat.xcframework
│   ├── Libavutil.xcframework
│   ├── Libswresample.xcframework
│   └── Libswscale.xcframework
├── Freedom/
│   └── libmpv.xcframework
└── README.md
```

`MPVKitDependencies/` 和 `Freedom/` 目录会保留 `.gitkeep`，但其中的 `.xcframework` 默认被 `.gitignore` 忽略，避免把大二进制依赖直接提交进 `main`。

`MPVKitDependencies/Libmpv.xcframework` 的模块名是：

```swift
import Libmpv
```

不是：

```swift
import libmpv
```

`Freedom/libmpv.xcframework` 是后续自由度独立内核占位。它的模块名、大小写和依赖结构必须等真实产物放入后再确认，不能直接假设它等同于 `MPVKitDependencies/Libmpv.xcframework`。

## 双后端隔离规则

```text
MPVKitBackend
  使用 MPVKit.xcframework
  依赖 MPVKitDependencies/ 下的 Libmpv 和 FFmpeg 组件
  不直接使用 Freedom/libmpv.xcframework

LibMPVBackend
  预留给 Freedom/libmpv.xcframework
  不直接复用 MPVKitDependencies/Libmpv.xcframework
  后续根据真实自由度产物确认模块名和渲染路径
```

如果两个后端需要同时存在，必须先确认：

```text
1. 模块名是否冲突
2. 是否都包含 FFmpeg/libmpv
3. 是否会产生 duplicate symbols
4. 是否都需要 Embed & Sign
5. 是否应通过编译开关隔离到不同构建
```

## UI 命名

```text
MPV    = MPVKit.xcframework
自由度 = Freedom/libmpv.xcframework
```

## 架构要求

必须包含 `ios-arm64`。推荐包含 `ios-arm64_x86_64-simulator`，方便后续模拟器验证。

## 接入规则

在完整依赖链路验证之前，不要提前把 MPV 相关 framework 加入 Xcode 的 `Link Binary With Libraries` 或 `Embed Frameworks`。

安装 MPVKit 核心依赖：

```bash
scripts/fetch_mpv_dependencies.sh
```

该脚本会从当前仓库 GitHub Release 下载 `MPVKit-xcframework.zip`，再调用：

```bash
scripts/install_mpv_dependencies.sh .mpv-cache/MPVKit-xcframework.zip
```

如果要临时使用其他地址：

```bash
MPVKIT_DEPS_URL="https://example.com/MPVKit-xcframework.zip" scripts/fetch_mpv_dependencies.sh
```

检查已安装依赖：

```bash
python3 scripts/check_mpv_installed_dependencies.py
```

真实接入时需要确认：

```text
1. framework 的模块名，尤其是 MPVKit 依赖 `Libmpv` 和自由度 `libmpv` 是否同名
2. Info.plist 支持的架构 slice
3. Swift Package binaryTarget 是否能被 GitHub Actions 下载
4. 手动 Link 时是否需要补齐所有间接依赖
5. 是否需要 Embed & Sign
6. 启动是否仍然闪退
```

## 体积建议

如果 `.xcframework` 很大，建议使用 Git LFS 或构建时从 Release 下载，不建议直接普通提交超大二进制。

## 冲突提醒

不要随意同时启用多个都内置 FFmpeg/libmpv 的大型 framework。`MPVKitDependencies/` 和 `Freedom/` 两条线之间要先确认链接关系，避免重复符号、模块名冲突或运行时冲突。
