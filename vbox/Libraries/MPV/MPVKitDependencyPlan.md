# MPVKit 静态依赖补齐计划

本文档记录 MPVKit 后续打开 `mpv_create → mpv_initialize` 前必须补齐的依赖。

## 当前结论

`MPVKit.xcframework` 是动态库，3.155 已验证可以随包嵌入并由 `dlopen` 动态加载。

`MPVKitDependencies/Libmpv.xcframework` 中的 `Libmpv.framework/Libmpv` 是静态库 archive。只要 App 代码直接 `import Libmpv` 并调用 `mpv_create`，链接器就会拉入完整 Libmpv/FFmpeg 静态依赖链。

3.153 的正式 IPA 编译失败已经证明：当前 Release 包只包含 `Libmpv + FFmpeg 7 件套`，不足以完成 `mpv_create` 静态链接。

## 已具备

```text
MPVKit.xcframework
MPVKitDependencies/Libmpv.xcframework
MPVKitDependencies/Libavcodec.xcframework
MPVKitDependencies/Libavdevice.xcframework
MPVKitDependencies/Libavfilter.xcframework
MPVKitDependencies/Libavformat.xcframework
MPVKitDependencies/Libavutil.xcframework
MPVKitDependencies/Libswresample.xcframework
MPVKitDependencies/Libswscale.xcframework
```

## 编译日志已确认缺失

3.153 链接失败日志中已出现以下缺失符号来源：

```text
VideoToolbox.framework
gmp.xcframework
Libass.xcframework
Libbluray.xcframework
lcms2.xcframework
```

其中 `VideoToolbox.framework` 是系统 framework，后续可由 `configure_mpvkit_link.rb` 自动注入。其余为第三方 binaryTarget，需要进入 MPVKit 依赖包或下载脚本。

## Package.swift 外部 binaryTarget 清单

当前 `MPVKit-binary-bundle.zip` 内的 `Package.swift` 声明了以下未随核心包安装的外部 binaryTarget：

```text
Libcrypto.xcframework
Libssl.xcframework
gmp.xcframework
nettle.xcframework
hogweed.xcframework
gnutls.xcframework
Libunibreak.xcframework
Libfreetype.xcframework
Libfribidi.xcframework
Libharfbuzz.xcframework
Libass.xcframework
Libsmbclient.xcframework
Libbluray.xcframework
Libuavs3d.xcframework
Libdovi.xcframework
MoltenVK.xcframework
Libshaderc_combined.xcframework
lcms2.xcframework
Libplacebo.xcframework
Libdav1d.xcframework
Libuchardet.xcframework
```

`Libluajit.xcframework` 只在 macOS 条件下使用，当前 iOS 阶段暂不列为必须项。

## 系统 framework 待确认

打开 Libmpv 静态初始化时，至少需要确认以下系统 framework：

```text
VideoToolbox.framework
CoreMedia.framework
CoreVideo.framework
AudioToolbox.framework
AVFoundation.framework
Metal.framework
```

最终清单以后续 CI 链接日志为准。

## 3.156 验证目标

3.156 只做检查和文档：

```text
1. 核心依赖缺失时让 CI 失败
2. 外部静态依赖缺失时只提示，不让 CI 失败
3. 不重新打开 import Libmpv
4. 不调用 mpv_create
5. 不接正式播放器 UI
```

## 3.157 自动安装目标

3.157 新增：

```text
scripts/mpvkit_external_dependencies.json
scripts/fetch_mpv_external_dependencies.py
```

CI 会先安装最小外部依赖集：

```text
gmp.xcframework
Libass.xcframework
Libbluray.xcframework
lcms2.xcframework
```

这些依赖来自 MPVKit `Package.swift` 中声明的官方 Release URL。3.157 仍不重新打开 `import Libmpv` 和 `mpv_create`，只验证外部依赖能被下载、解压并放入 `MPVKitDependencies/`。

## 后续步骤

```text
3.158：根据新 CI 链接日志判断是否需要第二批外部依赖
3.159：最小依赖补齐后，尝试重新打开 mpv_create 初始化探针
3.160：测试 loadfile，但仍不接正式 UI
```
