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

## 3.162 综合控制探针目标

3.161 真机截图已确认：

```text
loadfile命令已接受
事件：start-file / audio-reconfig / file-loaded
```

3.162 在不接正式 UI 的前提下，把验证面扩展到控制链路：

```text
1. loadfile 成功后读取 duration / time-pos / pause
2. 验证 pause=yes 和 pause=no
3. 验证 speed=1.25
4. 验证 seek 5 relative
5. 控制命令后再次读取属性并采样 MPV 事件
```

这一步仍不创建渲染层，不接 PlayerEngine 正式播放链路，不处理切片资源、网盘资源和弹幕。

## 3.163 最小 PlayerEngine 链路目标

3.163 合并原计划的事件循环和最小 `MPVPlayerEngine` 接入：

```text
1. MPVKitBackend 从一次性探针升级为可持有 mpv_handle 的最小后端
2. 建立后台 MPV 事件循环
3. 将 start-file / file-loaded / playback-restart / end-file / shutdown 转换为 PlayerEngineEvent
4. 周期性读取 time-pos / duration 并发送 progress
5. 实现 load / play / pause / seek / stop / setRate / setVolume / teardown
6. 设置页增加“运行MPV最小播放链路”
```

设置页测试链路：

```text
PlayerEngineController
→ MPVPlayerEngine
→ MPVKitBackend
→ libmpv
```

测试动作：

```text
load 测试媒体
play
seek 5
pause
play
stop
teardown
```

边界不变：

```text
vo=null / ao=null
不创建渲染层
不接正式播放器页面
不接切片资源
不接网盘资源
不接弹幕系统
```

## 3.164 全量诊断面板目标

为了加快真机验证节奏，3.164 将后续 MPV 内核层测试入口集中放到设置页，不再每个探针单独发版。

新增诊断项：

```text
1. MPV日志采样探针
2. MPV音频输出探针
3. MPV视频输出能力探针
4. MPV网络播放探针
5. MPV生命周期压力测试
6. 一键运行全部MPV诊断
```

一键诊断会顺序运行：

```text
loadfile 探针
综合控制探针
最小播放链路
日志采样
音频输出
视频输出能力
网络播放
生命周期压力
```

诊断边界：

```text
仍不接正式播放器页面
仍不处理切片资源
仍不处理网盘资源
仍不接弹幕系统
音频/视频输出只做能力探针，失败结果用于判断下一步渲染层方案
```

## 后续步骤

```text
3.165：根据 3.164 一键诊断结果集中修复事件循环、生命周期、音频或视频输出
3.166：诊断稳定后再进入普通 URL 真实播放测试页
```
