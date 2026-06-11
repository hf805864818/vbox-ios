# MPV framework 自动构建/打包脚本

这个目录用于维护 MPV 相关 `.xcframework` 的 GitHub Actions 构建与打包脚本。

## 当前分支目标

当前第一版先提供两类能力：

```text
1. 验证并打包已有 MPVKit.xcframework / libmpv.xcframework
2. 预留从源码编译 libmpv.xcframework 的入口
```

完整从源码编译 `libmpv.xcframework` 需要同时处理 FFmpeg、libass、freetype、harfbuzz、fribidi、zlib 等依赖，后续需要单独迭代。

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
  从源码构建 libmpv 的预留入口。当前不会假装完成源码编译，后续补齐依赖构建链。
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

source-build-libmpv
  预留源码编译入口，后续补齐后可输出 libmpv.xcframework。
```

## 为什么先做 package-prebuilt

MPV 从源码编译链路非常重，不适合直接一次性写死到 App 主构建里。先把 framework 的验证、打包、上传流程跑通，可以后续接入：

```text
GitHub Release 下载
Actions Artifact 下载
App workflow 自动使用 vbox/Libraries/MPV/*.xcframework
```
