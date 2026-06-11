# MPV framework 自动构建/打包脚本

这个目录用于维护 MPV 相关 `.xcframework` 的 GitHub Actions 构建与打包脚本。

## 当前分支目标

当前分支提供两类能力：

```text
1. 验证并打包已有 MPVKit.xcframework / libmpv.xcframework
2. 从源码尝试编译 libmpv.xcframework
```

源码模式会先编译 `FFmpeg`，再通过 `meson` 编译 `mpv/libmpv`，目标 slice 为：

```text
ios-arm64
ios-arm64-simulator
```

说明：MPV 源码构建链路很重，第一次跑 Actions 可能还需要根据失败日志调整 Meson 选项或补依赖。脚本已经保留 `MPV_EXTRA_MESON_OPTIONS` 用于后续快速修正。

## 推荐产物

```text
MPVKit.xcframework  → UI 显示“MPV”
libmpv.xcframework  → UI 显示“自由度”
```

## 脚本说明

```text
validate-xcframework.sh
  检查 .xcframework 是否存在、Info.plist 是否可读、是否包含 iOS 真机 arm64 slice。

package-xcframework.sh
  将 .xcframework 打包为 zip，输出校验信息，供 Actions 上传 artifact 或 Release。

build-libmpv-ios.sh
  从源码构建 FFmpeg + libmpv，并合成包含 ios-arm64 / ios-arm64-simulator 的 libmpv.xcframework。
```

## GitHub Actions

workflow 文件：

```text
.github/workflows/build-mpv-framework.yml
```

支持手动触发：

```text
package-prebuilt
  从 URL 下载 zip/tar/xcframework，验证后重新打包上传 artifact。

source-build-kingslay-libmpv
  使用 https://github.com/kingslay/FFmpegKit.git 的 SwiftPM 构建工具尝试输出 libmpv.xcframework。

source-build-libmpv
  源码编译 libmpv.xcframework，输出 zip 和 sha256。
```

## kingslay/FFmpegKit 路线

`kingslay/FFmpegKit` 的 `Libmpv.podspec` 使用 `Sources/libmpv.xcframework`，因此这个分支新增：

```text
scripts/mpv/build-kingslay-libmpv-ios.sh
```

默认执行：

```text
swift package --disable-sandbox BuildFFmpeg platforms=ios,isimulator enable-libfreetype enable-libfribidi enable-libharfbuzz enable-libass enable-FFmpeg enable-libmpv
```

如果 Actions 日志显示该仓库的参数格式不同，可以通过后续提交调整 `KINGS_LAY_PLATFORMS` 或构建参数。

## 为什么先做 package-prebuilt

MPV 从源码编译链路非常重，不适合直接一次性写死到 App 主构建里。先把 framework 的验证、打包、上传流程跑通，可以后续接入：

```text
GitHub Release 下载
Actions Artifact 下载
App workflow 自动使用 vbox/Libraries/MPV/*.xcframework
```
