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

## 3.158 初始化探针目标

3.158 在最小外部依赖集安装成功后，重新打开：

```text
import Libmpv
mpv_client_api_version
mpv_create
mpv_set_option_string(config=no / terminal=no / vo=null / ao=null)
mpv_initialize
mpv_terminate_destroy
```

同时 CI 注入脚本会自动 Link/Embed `MPVKitDependencies/` 下所有已安装的 `.xcframework`，并补充必要系统 framework / tbd：

```text
VideoToolbox.framework
CoreMedia.framework
CoreVideo.framework
AudioToolbox.framework
AVFoundation.framework
Metal.framework
Security.framework
libz.tbd
libbz2.tbd
libiconv.tbd
```

3.158 仍不加载媒体、不渲染、不接 PlayerViewsV2。若链接仍失败，按新日志继续补第二批外部依赖。

## 3.159 完整静态依赖目标

3.158 CI 日志确认最小外部依赖集不足，缺失符号覆盖：

```text
gnutls_*：gnutls / nettle / hogweed / gmp
pl_*：Libplacebo
shaderc_*：Libshaderc_combined
uavs3d_*：Libuavs3d
uchardet_*：Libuchardet
vk*：MoltenVK
init_linebreak / set_linebreaks_utf32：Libunibreak
```

3.159 调整为：

```text
1. 正式 IPA 和 Debug workflow 均使用 fetch_mpv_external_dependencies.py --all
2. check_mpv_installed_dependencies.py 在完整验证阶段要求外部静态依赖全部存在
3. fetch_mpv_dependencies.sh 内部核心检查使用 --allow-missing-external，避免核心包安装后、外部包安装前提前失败
4. configure_mpvkit_link.rb 使用显式静态依赖顺序注入，不再简单按文件名排序
5. 系统依赖提示与注入补充 QuartzCore / UIKit / IOSurface
```

## 3.160 C++ 标准库链接目标

3.159 CI 已确认完整外部静态依赖均下载、检查和注入成功，链接失败点继续推进到 C++ 标准库：

```text
std::runtime_error / std::logic_error / std::exception
vtable for std::length_error / std::out_of_range
___gxx_personality_v0
```

这些符号来自 `MoltenVK` 与 `Libshaderc_combined`，当前 App 主链接命令由 `clang` 发起，不会自动带上 C++ 标准库。3.160 只补充 `libc++.tbd` 到 CI 注入清单和检查脚本，不改播放器运行链路。

## 3.161 loadfile 探针目标

3.160 已在真机 App 内验证：

```text
MPVKit 动态库已随包嵌入
动态加载成功
Libmpv-imported
mpv_create 成功
mpv_initialize 成功
```

3.161 进入最小媒体加载验证：

```text
1. 新增 MPVKitBackend.runLoadfileProbe()
2. 使用 vo=null / ao=null，不创建渲染层
3. 使用公开测试媒体地址，只验证 loadfile 命令和 MPV 事件流
4. 设置页关于区域提供手动触发按钮
5. 不接正式播放器 UI、不接切片资源、不接网盘资源、不接弹幕系统
```

成功标准：

```text
loadfile 命令返回 >= 0
在等待窗口内收到 file-loaded 或 playback-restart
```

## 后续步骤

```text
3.162：根据 3.161 真机探针结果修正网络、事件循环或媒体加载参数
3.163：loadfile 成功后接 MPV 事件循环和状态同步，但仍不接正式 UI
```
